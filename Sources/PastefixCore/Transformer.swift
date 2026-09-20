import Foundation

/// Content handed to a transform. `text` is the current working buffer.
/// `richRTFD` carries the original clipboard's rich representation as RTFD
/// data (Sendable); only `RichToPlain` reads it.
public struct TransformInput: Sendable {
    public let text: String
    public let richRTFD: Data?

    public init(text: String, richRTFD: Data? = nil) {
        self.text = text
        self.richRTFD = richRTFD
    }
}

public enum TransformerSource: Sendable, Equatable {
    case builtin
    case shell(URL)
    case javascript(URL)
}

public enum TransformError: Error, Equatable {
    case richInputUnavailable
    case timeout
    case nonZeroExit(code: Int32, stderr: String)
    case scriptFailed(String)
}

public protocol Transformer: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    /// True only for transforms that need the original rich clipboard content.
    var requiresRichInput: Bool { get }
    var source: TransformerSource { get }
    /// Content kinds this transform is meant for. `nil` (the default) means always
    /// applicable. The palette lists matching transforms first; nothing is hidden.
    var applicableKinds: Set<ContentKind>? { get }
    /// Display group for browsing UIs (sidebar sections, palette subtitles). `nil` means
    /// uncategorised; scripts without a `category` header are shown under "Scripts".
    var category: String? { get }
    func apply(_ input: TransformInput) async throws -> String
}

public extension Transformer {
    var applicableKinds: Set<ContentKind>? { nil }
    var category: String? { nil }
}

/// Category names shared by the built-ins, the grouping code, and tests.
public enum TransformCategory {
    public static let layout = "Layout"
    public static let characters = "Characters"
    public static let urls = "URLs"
    public static let `case` = "Case"
    public static let scripts = "Scripts"
    /// Display order for the built-in categories; custom ones follow alphabetically, then Scripts.
    public static let builtinOrder = [layout, characters, urls, `case`]
}
