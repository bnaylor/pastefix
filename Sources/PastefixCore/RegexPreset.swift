import Foundation

/// A user-defined find & replace rule. Stored as settings JSON; surfaced as a transform.
public struct RegexPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    public var caseInsensitive: Bool
    public var anchorsMatchLines: Bool
    public var dotMatchesNewlines: Bool
    public var replaceAll: Bool

    public init(id: UUID = UUID(), name: String, pattern: String, replacement: String = "",
                caseInsensitive: Bool = false, anchorsMatchLines: Bool = true,
                dotMatchesNewlines: Bool = false, replaceAll: Bool = true) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.caseInsensitive = caseInsensitive
        self.anchorsMatchLines = anchorsMatchLines
        self.dotMatchesNewlines = dotMatchesNewlines
        self.replaceAll = replaceAll
    }

    public var regexOptions: NSRegularExpression.Options {
        var o: NSRegularExpression.Options = []
        if caseInsensitive { o.insert(.caseInsensitive) }
        if anchorsMatchLines { o.insert(.anchorsMatchLines) }
        if dotMatchesNewlines { o.insert(.dotMatchesLineSeparators) }
        return o
    }

    public func compile() throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: regexOptions) }
        catch { throw TransformError.invalidInput("Invalid pattern: \(error.localizedDescription)") }
    }

    /// `\n` → newline, `\t` → tab, `\\` → `\`; single left-to-right pass so `\\n` stays `\n` literally.
    public static func expandEscapes(_ template: String) -> String {
        var out = ""
        var it = template.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\\": out.append("\\")
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }
}
