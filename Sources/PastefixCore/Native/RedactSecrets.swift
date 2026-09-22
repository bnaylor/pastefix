import Foundation

public struct RedactSecrets: Transformer {
    public let id = "builtin.redactsecrets"
    public let name = "Redact Secrets"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.privacy
    public let applicableKinds: Set<ContentKind>? = [.secret]
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String {
        SecretRedactor.redact(input.text, matches: SecretDetector.scan(input.text))
    }
}
