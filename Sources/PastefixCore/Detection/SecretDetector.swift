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

/// Bounded-regex credential scanner. Every quantifier is bounded (Plan 8 lesson); the generic
/// key=value rule additionally requires a high-entropy value so `password=changeme` stays quiet.
public enum SecretDetector {
    public static let maxBytes = 1_048_576
    static let minEntropy = 3.5

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
        Rule(kind: .privateKey, regex: rx(#"-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----[\s\S]{0,8192}?-----END [A-Z ]{0,20}PRIVATE KEY-----"#), group: 0, needsEntropy: false),
        Rule(kind: .jwt, regex: rx(#"\b[A-Za-z0-9_-]{8,2048}\.[A-Za-z0-9_-]{8,4096}\.[A-Za-z0-9_-]{8,2048}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .passwordInURL, regex: rx(#"\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@]{1,64}:([^\s/@]{1,128})@"#, .caseInsensitive), group: 1, needsEntropy: false),
        Rule(kind: .genericAssignment, regex: rx(#"\b(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?token|client[_-]?secret)\b\s*[:=]\s*["']?([A-Za-z0-9_\-+/=.]{16,256})["']?"#, .caseInsensitive), group: 1, needsEntropy: true),
    ]

    public static func scan(_ text: String) -> [SecretMatch] {
        guard text.utf8.count <= maxBytes, !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(NSRange, SecretKind)] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, range: full) {
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound else { continue }
                let token = ns.substring(with: r)
                if rule.kind == .jwt, JWTDecoder.split(token) == nil { continue }
                if rule.needsEntropy, entropy(token) < minEntropy { continue }
                found.append((r, rule.kind))
            }
        }
        found.sort { a, b in a.0.location != b.0.location ? a.0.location < b.0.location : a.0.length > b.0.length }
        var out: [SecretMatch] = []; var cursor = 0
        for (r, kind) in found where r.location >= cursor {
            guard let range = Range(r, in: text) else { continue }
            out.append(SecretMatch(kind: kind, range: range)); cursor = NSMaxRange(r)
        }
        return out
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
    public static func redact(_ text: String, matches: [SecretMatch]) -> String {
        guard !matches.isEmpty else { return text }
        var out = ""; var cursor = text.startIndex
        for m in matches {
            out += text[cursor..<m.range.lowerBound]
            out += m.kind == .passwordInURL ? "[REDACTED]" : "[REDACTED \(m.kind.slug)]"
            cursor = m.range.upperBound
        }
        out += text[cursor...]
        return out
    }
}
