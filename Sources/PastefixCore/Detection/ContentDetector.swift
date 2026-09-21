import Foundation

public enum ContentDetector {
    /// Buffers larger than this are not inspected; the badge is a nicety, summon latency is not.
    public static let maxBytes = 1_048_576

    public static func detect(_ text: String) -> Set<ContentKind> {
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
        return kinds
    }

    private static let percentRegex = try! NSRegularExpression(pattern: "%[0-9A-Fa-f]{2}")
    private static let entityRegex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]{1,31});")
}
