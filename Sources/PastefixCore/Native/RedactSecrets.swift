import Foundation

public struct RedactSecrets: Transformer {
    public let id = "builtin.redactsecrets"
    public let name = "Redact Secrets"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.privacy
    public let applicableKinds: Set<ContentKind>? = [.secret]
    public var maxInputBytes: Int { SecretDetector.maxBytes }
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String {
        // Over the cap the scan does not run, so `redact` would return the input verbatim, the
        // coordinator would call that `.unchanged` and the user would be told nothing at all —
        // having just invoked the safety feature on a buffer that still holds the key. Refusing
        // out loud is the only honest answer.
        guard SecretDetector.isScannable(input.text) else {
            throw TransformError.invalidInput("Too large to scan for secrets (limit 256 KB)")
        }
        return SecretRedactor.redact(input.text, matches: SecretDetector.scan(input.text))
    }
}
