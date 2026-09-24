import Foundation

public enum SecretKind: String, CaseIterable, Sendable {
    case awsAccessKey, awsSecretKey, githubToken, anthropicKey, openAIKey, slackToken, stripeKey, googleAPIKey, privateKey, jwt, passwordInURL, genericAssignment
    public var displayName: String {
        switch self {
        case .awsAccessKey: "AWS access key"
        case .awsSecretKey: "AWS secret key"
        case .githubToken: "GitHub token"
        case .anthropicKey: "Anthropic key"
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
        case .anthropicKey: "anthropic-key"
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
/// stays quiet. A buffer over `maxBytes` is not scanned at all — `isScannable` is how a caller
/// tells that apart from a clean scan, and every caller must.
public enum SecretDetector {
    /// Measured on a 1 MB prose-like buffer: ~170ms, over the 150ms budget, so the cap is
    /// tightened to 256 KiB (Plan 11 Task 2, carried item C2).
    public static let maxBytes = 262_144
    /// The entropy bar, as a fraction of what the value's OWN alphabet could reach; see
    /// `normalisedEntropy`.
    static let minNormalisedEntropy = 0.75
    /// Values drawing on fewer distinct characters than this are not credentials, whatever they
    /// score: `abcabcabcabcabc1` uses four and reaches 0.91 of its tiny alphabet's maximum.
    static let minDistinctCharacters = 6
    /// How far past a BEGIN marker its matching END marker may sit. A PEM whose body exceeds
    /// this is not matched at all (a documented limit, pinned by `privateKeyBodyLimit`).
    static let maxPEMBodyLength = 16_384
    /// Shortest run worth handing to `JWTDecoder.split`: three segments of >= 8 base64url
    /// characters plus two dots cannot be shorter than 26, but 20 leaves room to spare.
    static let minJWTLength = 20
    /// A byte cap is not a cost cap (Plan 10 lesson): validating a JWT candidate costs ~15us, so
    /// a crafted buffer of thousands of minimal three-segment tokens would spend >100ms on the
    /// main actor even though none of them is a JWT. This budget bounds how many *weak*
    /// candidates (see `jwtStrength`) are validated. It never bounds the walk and never applies
    /// to a strong candidate, so a real JWT anywhere in the buffer is still found — an earlier
    /// version stopped the walk outright, so a buffer whose first 4 096 dotted tokens were junk
    /// hid every JWT that followed them.
    static let maxWeakJWTCandidates = 4_096

    private struct Rule {
        let kind: SecretKind; let regex: NSRegularExpression; let group: Int; let needsEntropy: Bool
        /// Drop one trailing "." from the captured range (see `genericAssignment`).
        var trimsSentencePeriod = false
    }
    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    /// Every vendor rule ends in `(?![A-Za-z0-9_\-])` (the AWS secret in the same lookahead over
    /// its own alphabet) rather than `\b`. `-` is a non-word character, so `\b` succeeds *inside*
    /// a hyphenated token: a 300-character `xoxb-` token matched its first 202 characters,
    /// redaction left the tail behind and the rescan came back clean — a false all-clear on a
    /// partially redacted secret. With the lookahead an over-long token does not match at all.
    private static let rules: [Rule] = [
        Rule(kind: .awsAccessKey, regex: rx(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .awsSecretKey, regex: rx(#"aws[_-]?secret[_-]?(?:access[_-]?)?key\W{0,5}([A-Za-z0-9/+=]{40})(?![A-Za-z0-9_\-/+=])"#, .caseInsensitive), group: 1, needsEntropy: false),
        Rule(kind: .githubToken, regex: rx(#"\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,255})(?![A-Za-z0-9_\-])"#), group: 0, needsEntropy: false),
        // Ordered before the OpenAI rule below: its "-" prefix is a *specific case* of the
        // OpenAI class, and for a real "sk-ant-…" token the two matches span the identical
        // range (the OpenAI class swallows "ant-…" too, so both greedy runs end at the same
        // place). That is a same-range tie, not a length or position difference, so it is not
        // rule-list order that decides the winner — the overlap resolution in `scan` sorts by
        // (location asc, length desc, `kindOrder` asc), and `kindOrder` is `SecretKind`
        // declaration order. `anthropicKey` is declared before `openAIKey` above for that
        // reason; the rule is still placed here, ahead of the OpenAI rule, purely so a reader
        // sees the more specific pattern first.
        Rule(kind: .anthropicKey, regex: rx(#"\bsk-ant-[A-Za-z0-9_-]{20,200}(?![A-Za-z0-9_\-])"#), group: 0, needsEntropy: false),
        Rule(kind: .openAIKey, regex: rx(#"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,200}(?![A-Za-z0-9_\-])"#), group: 0, needsEntropy: false),
        Rule(kind: .slackToken, regex: rx(#"\bxox[abprs]-[A-Za-z0-9-]{10,200}(?![A-Za-z0-9_\-])"#), group: 0, needsEntropy: false),
        Rule(kind: .stripeKey, regex: rx(#"\b(?:sk|rk)_live_[A-Za-z0-9]{16,200}(?![A-Za-z0-9_\-])"#), group: 0, needsEntropy: false),
        Rule(kind: .googleAPIKey, regex: rx(#"\bAIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_\-])"#), group: 0, needsEntropy: false),
        Rule(kind: .passwordInURL, regex: rx(#"\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@]{1,64}:([^\s/@]{1,128})@"#, .caseInsensitive), group: 1, needsEntropy: false),
        // The key name may be quoted (JSON, YAML, PHP) and the separator may be a PHP fat arrow;
        // without the optional quotes every `{"password": "..."}` blob — the commonest way a
        // credential reaches the clipboard — was silently missed. The trailing negative lookahead
        // makes an over-long value fail outright rather than match its first 256 characters and
        // leave a redacted tail behind.
        //
        // The value class is everything except whitespace and the characters that *delimit* a
        // value (quotes, comma, semicolon). An allow-list of `[A-Za-z0-9_\-+/=.]` missed the
        // commonest human password shape outright — `Tr0ub4dor&3xKcd-9zQ` and
        // `hunter2!SuperSecret99` both scanned clean — because `&`, `!`, `$`, `#`, `%` and `*` sat
        // outside it. `trimsSentencePeriod` then gives back the one character the wider class
        // over-claims: a value at the end of a sentence.
        Rule(kind: .genericAssignment, regex: rx(#"["']?\b(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?token|client[_-]?secret)\b["']?\s*(?:=>|[:=])\s*["']?([^\s"',;]{16,256})["']?(?![^\s"',;])"#, .caseInsensitive), group: 1, needsEntropy: true, trimsSentencePeriod: true),
    ]

    /// Declaration order of `SecretKind`, used as the deterministic tie-break when two rules
    /// match the identical range (`Array.sort` is not stable).
    private static let kindOrder: [SecretKind: Int] =
        Dictionary(uniqueKeysWithValues: SecretKind.allCases.enumerated().map { ($1, $0) })

    /// Whether `scan` will actually examine this text. A buffer over the cap is not scanned at
    /// all, and callers must be able to tell that apart from "scanned and clean": an empty result
    /// from an unscanned buffer is not evidence of anything. `PasteDocument.secretScanSkipped`,
    /// the "Not scanned for secrets" badge, `RedactSecrets` (which throws) and
    /// `HistoryItem.containsSecret == nil` are the four places that distinction is kept.
    public static func isScannable(_ text: String) -> Bool { text.utf8.count <= maxBytes }

    public static func scan(_ text: String) -> [SecretMatch] {
        guard isScannable(text), !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(range: NSRange, kind: SecretKind)] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, range: full) {
                var r = m.range(at: rule.group)
                guard r.location != NSNotFound else { continue }
                // A value class that admits punctuation also admits the full stop that ends the
                // sentence it sits in; redacting it swallowed the period. One only: a trailing
                // dot is a sentence, two is part of the token.
                if rule.trimsSentencePeriod, r.length > 0,
                   ns.character(at: NSMaxRange(r) - 1) == UInt16(UInt8(ascii: ".")) { r.length -= 1 }
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
        var weakBudget = maxWeakJWTCandidates
        while i < u.count {
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
            guard dots == 2 else { continue }
            switch jwtStrength(u, lo, hi) {
            case .no: continue
            case .weak:
                guard weakBudget > 0 else { continue }
                weakBudget -= 1
            case .strong: break
            }
            guard JWTDecoder.split(String(decoding: u[lo..<hi], as: UTF16.self)) != nil else { continue }
            out.append(NSRange(location: lo, length: hi - lo))
        }
        return out
    }

    /// How likely a three-segment token is to be a JWT, judged without allocating.
    ///
    /// Every condition below is *implied* by `JWTDecoder.split` succeeding, so `.no` rules out no
    /// real JWT, and the weak/strong split only decides who is allowed to exhaust the validation
    /// budget. Deductions, all from "the header base64url-decodes to a JSON object with an `alg`
    /// key":
    ///
    /// - The first header byte is `{` or JSON whitespace, and base64url maps each of those to
    ///   exactly one leading character: `{` -> "e", space -> "I", tab/newline -> "C", CR -> "D".
    /// - When that character is "e" the first byte is `{` (0x7B), whose low two bits are the top
    ///   two of the second base64url character's index, so that index is 48...63 — "w"..."z",
    ///   "0"..."9", "-", "_". This is the `.strong` test: a real JWT always passes it.
    /// - The smallest JSON object carrying an `alg` key is `{"alg":0}` — 9 bytes, 12 base64url
    ///   characters — so a shorter header cannot validate.
    /// - `JWTDecoder.decodeSegment` pads to a multiple of four, so a segment of one leftover
    ///   character never decodes; the payload need only be non-empty and decodable, and `e30`
    ///   (`{}`) is a real three-character payload, so the floor is two, not four.
    private static func jwtStrength(_ u: [UInt16], _ lo: Int, _ hi: Int) -> JWTStrength {
        var k = lo
        while k < hi, u[k] != dotUnit { k += 1 }
        let firstDot = k
        k += 1
        while k < hi, u[k] != dotUnit { k += 1 }
        let secondDot = k
        let header = firstDot - lo, payload = secondDot - firstDot - 1
        guard header >= 12, header % 4 != 1, payload >= 2, payload % 4 != 1,
              headerClosesAnObject(u, lo, firstDot) else { return .no }
        switch u[lo] {
        case 0x65:                                                          // "e" -> header byte 0 is '{'
            switch u[lo + 1] {
            case 0x77...0x7A, 0x30...0x39, 0x2D, 0x5F: return .strong       // w-z 0-9 - _
            default: return .no
            }
        case 0x49, 0x43, 0x44: return .weak                                 // I C D: leading JSON whitespace
        default: return .no
        }
    }

    private enum JWTStrength { case no, weak, strong }

    /// Whether the header segment's *last* decoded byte could close a JSON object. Also implied
    /// by `JWTDecoder.split` succeeding — `JSONSerialization` accepts no trailing garbage, so the
    /// header's last non-whitespace byte is `}` — and it is the condition that makes a crafted
    /// flood cheap, because a plausible prefix alone no longer buys a candidate a full
    /// validation: `eyJhbGciOiJI` decodes to `{"alg":"` and is rejected here, while
    /// `eyJhbGciOiJIUzI1NiJ9` (`{"alg":"HS256"}`) is not. Dotted source-code identifiers
    /// (`IConfiguration.Bind.Extensions`) fail it too. Only the final base64url group is decoded.
    private static func headerClosesAnObject(_ u: [UInt16], _ lo: Int, _ firstDot: Int) -> Bool {
        guard let a = b64Value(u[firstDot - 2]), let b = b64Value(u[firstDot - 1]) else { return false }
        let last: UInt8
        switch (firstDot - lo) % 4 {
        case 0: last = ((a & 0x03) << 6) | b          // third byte of a full 4-character group
        case 2: last = (a << 2) | (b >> 4)            // only byte of a 2-character tail
        case 3: last = ((a & 0x0F) << 4) | (b >> 2)   // second byte of a 3-character tail
        default: return false
        }
        return last == 0x7D || last == 0x20 || last == 0x09 || last == 0x0A || last == 0x0D
    }

    /// base64url alphabet index, or nil for a character outside it.
    private static func b64Value(_ c: UInt16) -> UInt8? {
        switch c {
        case 0x41...0x5A: UInt8(c - 0x41)             // A-Z -> 0...25
        case 0x61...0x7A: UInt8(c - 0x61 + 26)        // a-z -> 26...51
        case 0x30...0x39: UInt8(c - 0x30 + 52)        // 0-9 -> 52...61
        case 0x2D: 62                                 // -
        case 0x5F: 63                                 // _
        default: nil
        }
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
        // Placeholders read as random to Shannon: `your-token-here-xx` (0.87), `please-change-me-now`
        // (0.81) and `/var/run/secrets/tok` (0.83) all cleared the normalised bar. Requiring a
        // digit costs one pass and silences them. It also gives up values that are letters only
        // — roughly 3% of real keys, and the least likely shape for a machine-issued credential —
        // which is the accepted price for not crying wolf on every config template.
        guard s.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { return false }
        if uuidShape.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil { return true }
        return distinctCharacters(s) >= minDistinctCharacters && normalisedEntropy(s) >= minNormalisedEntropy
    }

    private static let uuidShape = rx(#"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)

    /// Shannon entropy as a fraction of the maximum the value's own *alphabet* could reach.
    ///
    /// Not the maximum its *length* could reach, which is the same quantity read the wrong way
    /// round. `H` is bounded by both `log2(alphabet)` and `log2(length)`, and for a real key the
    /// alphabet is the binding one — 4.0 bits/char for hex, whatever the length — while the length
    /// divisor keeps growing. Dividing by `log2(length)` therefore made the bar *harder* the
    /// longer, and so the stronger, the secret: measured over 200 random samples per length,
    /// 16-hex values were caught 173/200 and 40-, 48- and 64-hex values 0/200. A 256-bit key
    /// scanned clean. Dividing by `log2(distinct)` asks the question that was always meant —
    /// "given the characters this value actually uses, are they arranged randomly?" — and is
    /// length-independent, so it keeps the 16-character fix without inverting above it.
    ///
    /// It is a loose test on its own: any well-mixed value scores near 1.0, including
    /// `changeme-changeme` (0.97). The digit requirement and `minDistinctCharacters` in
    /// `isHighEntropy` are what keep placeholders quiet.
    static func normalisedEntropy(_ s: String) -> Double {
        let distinct = distinctCharacters(s)
        guard distinct > 1 else { return 0 }
        return entropy(s) / log2(Double(distinct))
    }

    /// How many distinct characters the value draws on — its observed alphabet.
    static func distinctCharacters(_ s: String) -> Int { Set(s).count }

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
