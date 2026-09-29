import Foundation

/// What a script takes (#67): `# pastefix: accepts = text | image`. An unrecognised value is kept,
/// not ignored — a key a user wrote that silently does nothing is worse than none.
public enum ScriptInputForm: Equatable, Sendable {
    case text
    case image
    case invalid(String)
}

public struct ScriptMetadata: Equatable, Sendable {
    public var name: String?
    public var accepts: ScriptInputForm = .text
    public var enabled: Bool
    public var order: Int?
    public var kinds: Set<ContentKind>?
    public var category: String?

    public init(name: String? = nil, enabled: Bool = true, order: Int? = nil, kinds: Set<ContentKind>? = nil, category: String? = nil,
                accepts: ScriptInputForm = .text) {
        self.name = name
        self.accepts = accepts
        self.enabled = enabled
        self.order = order
        self.kinds = kinds
        self.category = category
    }

    public static func parse(_ source: String) -> ScriptMetadata {
        var md = ScriptMetadata()
        let commentLead = CharacterSet(charactersIn: " \t#/*")
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(30) {
            let line = rawLine.trimmingCharacters(in: commentLead)
            guard line.lowercased().hasPrefix("pastefix:") else { continue }
            let body = line.dropFirst("pastefix:".count)
            let parts = body.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]
            switch key {
            case "name": md.name = value
            case "enabled": md.enabled = (value.lowercased() == "true")
            case "order": md.order = Int(value)
            case "kinds":
                // Match case-insensitively against the raw values rather than lowercasing into
                // `ContentKind(rawValue:)`: the camelCase kinds ("percentEncoded") never match once
                // the token has been lowercased.
                let parsed = value.split(separator: ",").compactMap { part -> ContentKind? in
                    let token = part.trimmingCharacters(in: .whitespaces).lowercased()
                    return ContentKind.allCases.first { $0.rawValue.lowercased() == token }
                }
                md.kinds = parsed.isEmpty ? nil : Set(parsed)
            case "accepts":
                switch value.lowercased() {
                case "text": md.accepts = .text
                case "image": md.accepts = .image
                default: md.accepts = .invalid(value)
                }
            case "category":
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                md.category = trimmed.isEmpty ? nil : trimmed
            default: break
            }
        }
        return md
    }
}
