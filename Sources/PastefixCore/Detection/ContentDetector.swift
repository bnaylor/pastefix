import Foundation

public enum ContentDetector {
    /// Buffers larger than this are not inspected. Detection now runs off the main actor (Plan
    /// 13), so this bounds work, not summon latency. Note the URL rule has its own tighter
    /// bound: `.url` is never reported above `URLFinder.maxBytes` (256 KB) even though the
    /// other rules run to 1 MB.
    public static let maxBytes = 1_048_576

    /// Scans `text` for every kind, including `.secret`.
    ///
    /// Callers that need the individual secret ranges as well should call `SecretDetector.scan`
    /// once and use `detect(_:secrets:)` instead: this wrapper's scan is not shared, so doing
    /// both pays the (up to 256 KB) scan twice per discrete event.
    public static func detect(_ text: String) -> Set<ContentKind> {
        detect(text, secrets: SecretDetector.scan(text))
    }

    /// As `detect(_:)`, but takes an already-computed secret scan of the *same* text: `.secret`
    /// is inserted when `secrets` is non-empty and no scan is run here. Passing matches from a
    /// different string simply mislabels the buffer; passing `[]` means "no secrets", not
    /// "unknown".
    public static func detect(_ text: String, secrets: [SecretMatch]) -> Set<ContentKind> {
        guard text.utf8.count <= maxBytes else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var kinds: Set<ContentKind> = []
        if !URLFinder.find(in: text).isEmpty { kinds.insert(.url) }
        if let first = trimmed.first, first == "{" || first == "[",
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
            kinds.insert(.json)
        }
        if ColorLiteral.parse(trimmed) != nil { kinds.insert(.color) }
        if JWTDecoder.split(trimmed) != nil { kinds.insert(.jwt) }
        else if Base64Codec.looksLikeBase64(trimmed) { kinds.insert(.base64) }
        if percentRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil { kinds.insert(.percentEncoded) }
        if entityRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil { kinds.insert(.htmlEntities) }
        if MarkdownDetector.looksLikeMarkdown(text) { kinds.insert(.markdown) }
        if !secrets.isEmpty { kinds.insert(.secret) }
        return kinds
    }

    private static let percentRegex = try! NSRegularExpression(pattern: "%[0-9A-Fa-f]{2}")
    private static let entityRegex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]{1,31});")
}
