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

    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, replacement, caseInsensitive, anchorsMatchLines, dotMatchesNewlines, replaceAll
    }

    /// Tolerant decoding: every flag falls back to the memberwise default rather than failing.
    /// The stored array is read with `try?` and falls back to `[]`, so a synthesized (all-keys-
    /// required) decoder would let one payload written by an older or newer build — or one
    /// hand-edited preset — wipe every preset the user has. Adding a field stays additive.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.pattern = try c.decode(String.self, forKey: .pattern)
        self.replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        self.caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        self.anchorsMatchLines = try c.decodeIfPresent(Bool.self, forKey: .anchorsMatchLines) ?? true
        self.dotMatchesNewlines = try c.decodeIfPresent(Bool.self, forKey: .dotMatchesNewlines) ?? false
        self.replaceAll = try c.decodeIfPresent(Bool.self, forKey: .replaceAll) ?? true
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

    /// Expands the escapes a single-line replacement field can't hold literally, and hands the
    /// result on as an **ICU template** — which is the whole subtlety here.
    ///
    /// `NSRegularExpression.replacementString(for:in:offset:template:)` reads the result again:
    /// `$1` is a group reference, and a backslash escapes the character after it. So a backslash
    /// this function emits raw is eaten a second time, and the user never sees it — `\\` produced
    /// nothing at all and `\d` produced a bare `d`. Every backslash that must survive to the
    /// output is therefore emitted **doubled**.
    ///
    /// Single left-to-right pass, so `\\n` is an escaped backslash followed by `n`, not a newline:
    /// - `\n` → newline, `\t` → tab (real characters; ICU passes them through)
    /// - `\\` → `\\` → one literal backslash in the output
    /// - `\$` → `\$` → kept as-is, so ICU escapes the dollar into a literal `$`
    /// - any other `\x` → `\\x` → the escape survives verbatim (`\d` stays `\d`)
    /// - a trailing lone `\` → `\\` → one literal backslash
    public static func expandEscapes(_ template: String) -> String {
        var out = ""
        var it = template.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\\": out.append("\\\\")
            case "$": out.append("\\$")
            case let other?: out.append("\\\\"); out.append(other)
            case nil: out.append("\\\\")
            }
        }
        return out
    }
}
