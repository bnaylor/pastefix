import Testing
@testable import PastefixCore

@Suite struct RedactSecretsTests {
    @Test func metadataAndApply() async throws {
        let t = RedactSecrets()
        #expect(t.id == "builtin.redactsecrets" && t.name == "Redact Secrets" && t.category == TransformCategory.privacy && t.applicableKinds == [.secret] && !t.requiresRichInput)
        #expect(try await t.apply(TransformInput(text: "x AKIAIOSFODNN7EXAMPLE y")) == "x [REDACTED aws-access-key] y")
        #expect(try await t.apply(TransformInput(text: "nothing here")) == "nothing here")
    }
    @Test func oversizeInputThrowsInsteadOfSilentlyDoingNothing() async throws {
        // Over the cap the scan never runs, so redaction returned the input verbatim, the
        // coordinator called that `.unchanged` and the error message was cleared: the user
        // invoked the safety feature on a buffer holding a live key and was told nothing.
        let t = RedactSecrets()
        let oversize = String(repeating: "a", count: SecretDetector.maxBytes) + " AKIAIOSFODNN7EXAMPLE"
        #expect(!SecretDetector.isScannable(oversize))
        await #expect(throws: TransformError.invalidInput("Too large to scan for secrets (limit 256 KB)")) {
            _ = try await t.apply(TransformInput(text: oversize))
        }
        // At the cap exactly it still works.
        let atCap = String(repeating: "a", count: SecretDetector.maxBytes - 21) + " AKIAIOSFODNN7EXAMPLE"
        #expect(atCap.utf8.count == SecretDetector.maxBytes)
        #expect(try await t.apply(TransformInput(text: atCap)).hasSuffix("[REDACTED aws-access-key]"))
    }
}
