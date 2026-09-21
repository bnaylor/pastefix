import Foundation

enum JSONReformat {
    static func parse(_ text: String) throws -> Any {
        guard let data = text.data(using: .utf8) else { throw TransformError.invalidInput("Not valid JSON: not UTF-8") }
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String ?? ns.localizedDescription)
                .split(separator: "\n").first.map(String.init) ?? "parse error"
            throw TransformError.invalidInput("Not valid JSON: \(detail)")
        }
    }
    static func render(_ object: Any, pretty: Bool) throws -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { opts.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: object, options: opts)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct JSONPrettify: Transformer {
    public let id = "builtin.json.pretty", name = "JSON Prettify", requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.json]
    public let category: String? = TransformCategory.data
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String { try JSONReformat.render(JSONReformat.parse(input.text), pretty: true) }
}

public struct JSONMinify: Transformer {
    public let id = "builtin.json.minify", name = "JSON Minify", requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.json]
    public let category: String? = TransformCategory.data
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String { try JSONReformat.render(JSONReformat.parse(input.text), pretty: false) }
}

/// Wraps the whole buffer as one JSON string literal.
public struct JSONEscape: Transformer {
    public let id = "builtin.json.escape", name = "Escape as JSON String", requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = nil
    public let category: String? = TransformCategory.data
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String {
        try JSONReformat.render(input.text, pretty: false)
    }
}
