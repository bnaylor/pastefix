import Foundation

/// Content handed to a transform. `text` is the current working buffer — `""` when the session is
/// showing an image. `richRTFD` carries the original clipboard's rich representation as RTFD data
/// (Sendable); only `RichToPlain` and `RichToMarkdown` read it. `image` is the current image entry's
/// PNG, or nil when the session is showing text (Plan 20).
public struct TransformInput: Sendable {
    public let text: String
    public let richRTFD: Data?
    public let image: Data?
    /// The selected region of `image`, for a `RegionImageTransformer` (crop). Nil otherwise.
    public let region: ImageRegion?

    public init(text: String, richRTFD: Data? = nil, image: Data? = nil, region: ImageRegion? = nil) {
        self.text = text
        self.richRTFD = richRTFD
        self.image = image
        self.region = region
    }
}

/// What a transform produced (Plan 20). Text and image results become the session's next undo
/// entry; `nothingToDo` pushes nothing and carries the sentence the user sees instead — how
/// Strip Image Metadata says there was nothing to remove, rather than silently re-encoding.
/// `note` on an image result is shown after it lands ("Removed location and camera details.").
public enum TransformOutput: Sendable, Equatable {
    case text(String)
    case image(Data, note: String? = nil)
    case nothingToDo(String)
}

/// What a transform can run on.
///
/// Deliberately separate from `ContentKind`: kinds drive detection-based *promotion* (what sorts
/// first in the palette), while a form is *applicability* (what can run at all). Collapsing them
/// would make "promoted" and "possible" one axis, and they are not — a JSON transform is promoted
/// for JSON and still applicable to any text.
public enum ContentForm: Sendable, Hashable {
    case text
    case image
}

public enum TransformerSource: Sendable, Equatable {
    case builtin
    case shell(URL)
    case javascript(URL)
    /// A user-defined regex find & replace rule, identified by its `RegexPreset.id`.
    case preset(UUID)
}

public enum TransformError: Error, Equatable {
    case richInputUnavailable
    case timeout
    case nonZeroExit(code: Int32, stderr: String)
    case scriptFailed(String)
    /// Input could not be interpreted by the transform (bad Base64, malformed JSON, not a
    /// colour…). The buffer is left unchanged.
    case invalidInput(String)
}

/// Defaults for `Transformer.maxInputBytes` and `Transformer.timeout`: what a transform gets
/// unless it declares its own tighter (or looser) bound.
public enum TransformLimits {
    public static let defaultMaxInputBytes = 1_048_576
    public static let defaultTimeout: TimeInterval = 3
}

/// How Save should write the buffer. Set by an `OutputModeTransformer`; lives on the document for the session.
public enum OutputMode: String, Sendable, Equatable {
    case plain
    /// Render the buffer as Markdown: Save writes HTML + RTF alongside the Markdown source.
    case renderedMarkdown
}

/// A transform that, besides (possibly) changing the text, chooses how the buffer is written on Save.
/// This is the only channel through which a transform influences Save.
public protocol OutputModeTransformer: Transformer {
    var outputMode: OutputMode { get }
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
    /// Which content forms this transform can run on. Defaults to `[.text]`.
    ///
    /// The default is text and it is deliberate: every transform that predates image sessions
    /// declares nothing, and a new one must not claim it handles images by omission.
    var acceptedForms: Set<ContentForm> { get }
    /// Display group for browsing UIs (sidebar sections, palette subtitles). `nil` means
    /// uncategorised; scripts without a `category` header are shown under "Scripts".
    var category: String? { get }
    /// Largest `TransformInput.text` (UTF-8 bytes) this transform accepts. The coordinator
    /// refuses larger buffers before calling `apply`, so a body need not re-check unless it is
    /// also reachable outside the coordinator (presets' Settings preview, for one).
    var maxInputBytes: Int { get }
    /// Wall-clock budget for `apply`, enforced by the coordinator through `Deadline.run`. A body
    /// that can be interrupted should check `Task.isCancelled`; one that cannot relies on
    /// `maxInputBytes` to keep it short.
    var timeout: TimeInterval { get }
    func apply(_ input: TransformInput) async throws -> String
    /// The transform's result as text or an image (Plan 20). A protocol **requirement**, not only
    /// an extension method: the coordinator calls through `any Transformer`, and an extension-only
    /// method would dispatch statically to the default below, so an image transform's own body
    /// would never run. Every text transform takes the default and is unchanged.
    func transform(_ input: TransformInput) async throws -> TransformOutput
}

public extension Transformer {
    var applicableKinds: Set<ContentKind>? { nil }
    var acceptedForms: Set<ContentForm> { [.text] }
    var category: String? { nil }
    var maxInputBytes: Int { TransformLimits.defaultMaxInputBytes }
    var timeout: TimeInterval { TransformLimits.defaultTimeout }
    func transform(_ input: TransformInput) async throws -> TransformOutput {
        .text(try await apply(input))
    }
}

/// Category names shared by the built-ins, the grouping code, and tests.
public enum TransformCategory {
    public static let layout = "Layout"
    public static let richText = "Rich Text"
    public static let characters = "Characters"
    public static let urls = "URLs"
    public static let `case` = "Case"
    public static let data = "Data"
    public static let colors = "Colors"
    public static let scripts = "Scripts"
    public static let privacy = "Privacy"
    /// Transforms that read an image (Plan 21): Extract Text (OCR).
    public static let images = "Images"
    public static let presets = "Presets"
    /// Display order for the built-in categories; custom ones follow alphabetically, then Scripts.
    public static let builtinOrder = [layout, richText, characters, urls, `case`, data, colors, privacy, images, presets]
}
