import Foundation

/// What the detector recognised in the working buffer. Transforms may opt in to
/// kinds via `Transformer.applicableKinds`; the palette shows those first.
public enum ContentKind: String, CaseIterable, Sendable, Codable {
    case url
    case json

    /// Label for the "Detected: …" badge.
    public var displayName: String {
        switch self {
        case .url: return "URL"
        case .json: return "JSON"
        }
    }
}
