import Foundation

public enum SecretKind: String, CaseIterable, Sendable {
    case awsAccessKey, awsSecretKey, githubToken, openAIKey, slackToken, stripeKey, googleAPIKey, privateKey, jwt, passwordInURL, genericAssignment
    public var displayName: String {
        switch self {
        case .awsAccessKey: "AWS access key"
        case .awsSecretKey: "AWS secret key"
        case .githubToken: "GitHub token"
        case .openAIKey: "OpenAI key"
        case .slackToken: "Slack token"
        case .stripeKey: "Stripe key"
        case .googleAPIKey: "Google API key"
        case .privateKey: "private key"
        case .jwt: "JWT"
        case .passwordInURL: "password in URL"
        case .genericAssignment: "credential assignment"
        }
    }
    public var slug: String {
        switch self {
        case .awsAccessKey: "aws-access-key"
        case .awsSecretKey: "aws-secret-key"
        case .githubToken: "github-token"
        case .openAIKey: "openai-key"
        case .slackToken: "slack-token"
        case .stripeKey: "stripe-key"
        case .googleAPIKey: "google-api-key"
        case .privateKey: "private-key"
        case .jwt: "jwt"
        case .passwordInURL: "password"
        case .genericAssignment: "credential"
        }
    }
}

public struct SecretMatch: Sendable, Equatable {
    public let kind: SecretKind
    /// The token to redact. For `.passwordInURL` this is the password only.
    public let range: Range<String.Index>
}

/// Bounded credential scanner. Every regex quantifier is bounded (Plan 8 lesson) and the two
/// rules that a bounded regex still could not do in linear time — JWTs and PEM private-key
/// blocks — are hand-written left-to-right scans instead (see `jwtRanges` / `privateKeyRanges`).
/// The generic key=value rule additionally requires a high-entropy value so `password=changeme`
/// stays quiet.
public enum SecretDetector {
    /// Measured on a 1 MB prose-like buffer: ~170ms, over the 150ms budget, so the cap is
    /// tightened to 256 KiB (Plan 11 Task 2, carried item C2).
    public static let maxBytes = 262_144
    /// Shannon entropy caps at log2(n) bits/char for an n-character value, so a fixed 3.5-bit
    /// bar is a far harder test at 16 characters (ceiling 4.0) than at 40 — measured, a random
    /// 16-hex value cleared it only 11% of the time. The bar is a fraction of the achievable
    /// maximum instead; see `isHighEntropy`.
    static let minNormalisedEntropy = 0.75
    /// How far past a BEGIN marker its matching END marker may sit. A PEM whose body exceeds
    /// this is not matched at all (a documented limit, pinned by `privateKeyBodyLimit`).
    static let maxPEMBodyLength = 16_384
    /// Shortest run worth handing to `JWTDecoder.split`: three segments of >= 8 base64url
    /// characters plus two dots cannot be shorter than 26, but 20 leaves room to spare.
    static let minJWTLength = 20
    /// A byte cap is not a cost cap (Plan 10 lesson): validating a JWT candidate costs ~15us, so
    /// a crafted 256 KB buffer of ~8 500 minimal three-segment tokens would spend 130ms on the
    /// main actor even though none of them is a JWT. Validation stops after this many candidates
    /// that survive the exact shape pre-filter. Ordinary text produces none, and 256 KB cannot
    /// hold anywhere near this many *real* JWTs (they run to hundreds of characters each), so the
    /// cap can only bite on junk.
    static let maxJWTCandidates = 4_096

    private struct Rule { let kind: SecretKind; let regex: NSRegularExpression; let group: Int; let needsEntropy: Bool }
    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let rules: [Rule] = [
        Rule(kind: .awsAccessKey, regex: rx(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .awsSecretKey, regex: rx(#"aws[_-]?secret[_-]?(?:access[_-]?)?key\W{0,5}([A-Za-z0-9/+=]{40})"#, .caseInsensitive), group: 1, needsEntropy: false),
        Rule(kind: .githubToken, regex: rx(#"\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,255})\b"#), group: 0, needsEntropy: false),
        Rule(kind: .openAIKey, regex: rx(#"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,200}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .slackToken, regex: rx(#"\bxox[abprs]-[A-Za-z0-9-]{10,200}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .stripeKey, regex: rx(#"\b(?:sk|rk)_live_[A-Za-z0-9]{16,200}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .googleAPIKey, regex: rx(#"\bAIza[0-9A-Za-z_-]{35}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .passwordInURL, regex: rx(#"\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@]{1,64}:([^\s/@]{1,128})@"#, .caseInsensitive), group: 1, needsEntropy: false),
        // The key name may be quoted (JSON, YAML, PHP) and the separator may be a PHP fat arrow;
        // without the optional quotes every `{"password": "..."}` blob — the commonest way a
        // credential reaches the clipboard — was silently missed. The trailing negative lookahead
        // makes an over-long value fail outright rather than match its first 256 characters and
        // leave a redacted tail behind.
        Rule(kind: .genericAssignment, regex: rx(#"["']?\b(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?token|client[_-]?secret)\b["']?\s*(?:=>|[:=])\s*["']?([A-Za-z0-9_\-+/=.]{16,256})["']?(?![A-Za-z0-9_\-+/=.])"#, .caseInsensitive), group: 1, needsEntropy: true),
    ]

    /// Declaration order of `SecretKind`, used as the deterministic tie-break when two rules
    /// match the identical range (`Array.sort` is not stable).
    private static let kindOrder: [SecretKind: Int] =
        Dictionary(uniqueKeysWithValues: SecretKind.allCases.enumerated().map { ($1, $0) })

    public static func scan(_ text: String) -> [SecretMatch] {
        guard text.utf8.count <= maxBytes, !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(range: NSRange, kind: SecretKind)] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, range: full) {
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound else { continue }
                if rule.needsEntropy, !isHighEntropy(ns.substring(with: r)) { continue }
                found.append((r, rule.kind))
            }
        }
        found += privateKeyRanges(in: text, ns: ns).map { ($0, SecretKind.privateKey) }
        found += jwtRanges(in: text).map { ($0, SecretKind.jwt) }
        // Deterministic order: location asc, length desc, then SecretKind declaration order asc.
        found.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return (kindOrder[a.kind] ?? 0) < (kindOrder[b.kind] ?? 0)
        }
        var out: [SecretMatch] = []; var cursor = 0
        for (r, kind) in found where r.location >= cursor {
            guard let range = Range(r, in: text) else { continue }
            out.append(SecretMatch(kind: kind, range: range)); cursor = NSMaxRange(r)
        }
        return out
    }

    // MARK: - JWTs

    private static let dotUnit = UInt16(UInt8(ascii: "."))
    /// A-Z, a-z, 0-9, '-', '.', '_' — every character that can legally occur in a JWT.
    private static func isJWTUnit(_ c: UInt16) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: true
        default: false
        }
    }

    /// Finds JWTs with one left-to-right walk. The obvious three-class regex
    /// (`[A-Za-z0-9_-]{8,2048}\.…`) backtracks catastrophically: the class contains `-`, which is
    /// also a non-word character, so `\b` matches every few characters inside an unbroken
    /// base64url run and the engine retries ~2040 lengths from each of thousands of positions —
    /// measured 10 s at 256 KB and 41 s at 1 MB, on the main actor. Instead, split the buffer
    /// into maximal runs of JWT-legal characters and hand the plausible ones to
    /// `JWTDecoder.split`, which is the actual validator (three base64url segments, JSON header
    /// with an `alg`). Treating every non-JWT character as a delimiter is a superset of the
    /// "whitespace-delimited tokens" the spec asks for: it also finds `token=<jwt>` and
    /// `?id_token=<jwt>&state=1`, both of which the old regex found and a whitespace-only split
    /// would lose.
    private static func jwtRanges(in text: String) -> [NSRange] {
        let u = Array(text.utf16)
        var out: [NSRange] = []
        var i = 0
        var budget = maxJWTCandidates
        while i < u.count, budget > 0 {
            guard isJWTUnit(u[i]) else { i += 1; continue }
            var end = i
            while end < u.count, isJWTUnit(u[end]) { end += 1 }
            defer { i = end }
            // A sentence-final "." or a leading one is not part of the token.
            var lo = i, hi = end
            while lo < hi, u[lo] == dotUnit { lo += 1 }
            while hi > lo, u[hi - 1] == dotUnit { hi -= 1 }
            guard hi - lo >= minJWTLength else { continue }
            var dots = 0
            for k in lo..<hi where u[k] == dotUnit {
                dots += 1
                if dots > 2 { break }
            }
            guard dots == 2, isPlausibleJWTShape(u, lo, hi) else { continue }
            budget -= 1
            guard JWTDecoder.split(String(decoding: u[lo..<hi], as: UTF16.self)) != nil else { continue }
            out.append(NSRange(location: lo, length: hi - lo))
        }
        return out
    }

    /// Exact, allocation-free pre-filter run before the expensive validation. Every condition
    /// here is implied by `JWTDecoder.split` succeeding, so it rules out no real JWT; it only
    /// spares a buffer of thousands of dotted junk tokens the base64 decode, the string churn and
    /// the throwing `JSONSerialization` parse that each candidate would otherwise pay in full.
    ///
    /// - The header decodes to a JSON *object*, so its first byte is `{` or JSON whitespace, and
    ///   base64url maps each of those to exactly one leading character: `{` -> "e", space -> "I",
    ///   tab/newline -> "C", carriage return -> "D".
    /// - The smallest JSON object carrying an `alg` key is `{"alg":0}` — 9 bytes, 12 base64url
    ///   characters — so a shorter header segment cannot validate.
    /// - A base64 group of one leftover character never decodes, whatever the padding.
    private static func isPlausibleJWTShape(_ u: [UInt16], _ lo: Int, _ hi: Int) -> Bool {
        switch u[lo] {
        case 0x65, 0x49, 0x43, 0x44: break                      // e I C D
        default: return false
        }
        var firstDot = lo, secondDot = lo
        var k = lo
        while k < hi, u[k] != dotUnit { k += 1 }
        firstDot = k; k += 1
        while k < hi, u[k] != dotUnit { k += 1 }
        secondDot = k
        let header = firstDot - lo, payload = secondDot - firstDot - 1
        return header >= 12 && header % 4 != 1 && payload >= 4 && payload % 4 != 1
    }

    // MARK: - PEM private-key blocks

    private static let pemBegin = rx(#"-----BEGIN ([A-Z ]{0,20})PRIVATE KEY-----"#)
    private static let pemEnd = rx(#"-----END ([A-Z ]{0,20})PRIVATE KEY-----"#)

    /// Finds PEM blocks in linear time. The original lazy body class (`[\s\S]{0,8192}?`) was
    /// O(n x 8192) — 1 MB of unterminated BEGIN markers took 3.0 s — and a per-BEGIN literal
    /// search over a 16 KB window is the same shape (249 ms at the 256 KB cap). Instead both
    /// markers are found by one bounded anchored regex each, and every BEGIN binary-searches the
    /// END index for the first END at or after it whose label matches and that ends within
    /// `maxPEMBodyLength` characters. A body longer than that window is not matched at all.
    private static func privateKeyRanges(in text: String, ns: NSString) -> [NSRange] {
        let full = NSRange(location: 0, length: ns.length)
        let begins = pemBegin.matches(in: text, range: full)
        guard !begins.isEmpty else { return [] }
        let ends: [(start: Int, end: Int, label: String)] = pemEnd.matches(in: text, range: full).map {
            let l = $0.range(at: 1)
            return ($0.range.location, NSMaxRange($0.range), l.location == NSNotFound ? "" : ns.substring(with: l))
        }
        var out: [NSRange] = []
        for m in begins {
            let labelRange = m.range(at: 1)
            let label = labelRange.location == NSNotFound ? "" : ns.substring(with: labelRange)
            let from = NSMaxRange(m.range)
            let windowEnd = from + min(maxPEMBodyLength, ns.length - from)
            var lo = 0, hi = ends.count
            while lo < hi { let mid = (lo + hi) / 2; if ends[mid].start < from { lo = mid + 1 } else { hi = mid } }
            var i = lo
            while i < ends.count, ends[i].end <= windowEnd {
                if ends[i].label == label {
                    out.append(NSRange(location: m.range.location, length: ends[i].end - m.range.location))
                    break
                }
                i += 1
            }
        }
        return out
    }

    // MARK: - Entropy

    /// Whether a generic `key = value` value looks random enough to be a credential.
    ///
    /// A v4 UUID scores only 3.39 bits/char — *below* `changeme-changeme` — because 36 characters
    /// is a poor sample of a 122-bit secret, so no threshold on Shannon entropy can separate the
    /// two. UUID-shaped values are accepted on shape instead; they only ever reach here behind a
    /// credential key name (`api_key = <uuid>`), so a bare `id: <uuid>` still stays quiet.
    static func isHighEntropy(_ s: String) -> Bool {
        if uuidShape.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil { return true }
        return normalisedEntropy(s) >= minNormalisedEntropy
    }

    private static let uuidShape = rx(#"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)

    /// Shannon entropy as a fraction of the maximum a value of this length could reach.
    /// Capped at 64 characters so a long value is not held to an ever-rising bar.
    static func normalisedEntropy(_ s: String) -> Double {
        let n = min(s.count, 64)
        guard n > 1 else { return 0 }
        return entropy(s) / log2(Double(n))
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in let p = Double(c) / n; return acc - p * log2(p) }
    }
}

public enum SecretRedactor {
    /// Replaces every match with a typed token. `matches` must hold ranges into `text`, but need
    /// not be sorted or disjoint: they are sorted by start and any match overlapping one already
    /// emitted is dropped, so a careless caller gets a sensible string rather than a trap.
    public static func redact(_ text: String, matches: [SecretMatch]) -> String {
        guard !matches.isEmpty else { return text }
        var out = ""; var cursor = text.startIndex
        for m in matches.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard m.range.lowerBound >= cursor else { continue }
            out += text[cursor..<m.range.lowerBound]
            // Uniformly typed, including the URL password: a bare "[REDACTED]" sits inside the
            // password class [^\s/@], so the detector matched its own output and the badge never
            // cleared. The space in "[REDACTED password]" is what makes the output quiescent.
            out += "[REDACTED \(m.kind.slug)]"
            cursor = m.range.upperBound
        }
        out += text[cursor...]
        return out
    }
}
