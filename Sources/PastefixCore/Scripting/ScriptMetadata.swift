import Foundation

public struct ScriptMetadata: Equatable, Sendable {
    public var name: String?
    public var enabled: Bool
    public var order: Int?

    public init(name: String? = nil, enabled: Bool = true, order: Int? = nil) {
        self.name = name
        self.enabled = enabled
        self.order = order
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
            default: break
            }
        }
        return md
    }
}
