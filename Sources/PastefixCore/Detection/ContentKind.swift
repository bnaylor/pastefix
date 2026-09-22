import Foundation

/// What the detector recognised in the working buffer. Transforms may opt in to
/// kinds via `Transformer.applicableKinds`; the palette shows those first.
public enum ContentKind: String, CaseIterable, Sendable, Codable {
    case url
    case json
    case color
    case jwt
    case base64
    case percentEncoded
    case htmlEntities
    case markdown
    case secret

    /// Label for the "Detected: …" badge.
    public var displayName: String {
        switch self {
        case .url: return "URL"
        case .json: return "JSON"
        case .color: return "Color"
        case .jwt: return "JWT"
        case .base64: return "Base64"
        case .percentEncoded: return "Percent-encoded"
        case .htmlEntities: return "HTML entities"
        case .markdown: return "Markdown"
        case .secret: return "Secrets"
        }
    }
}
