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
        return kinds
    }
}
