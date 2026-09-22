import Testing
@testable import PastefixCore

@Suite struct RedactSecretsTests {
    @Test func metadataAndApply() async throws {
        let t = RedactSecrets()
        #expect(t.id == "builtin.redactsecrets" && t.name == "Redact Secrets" && t.category == TransformCategory.privacy && t.applicableKinds == [.secret] && !t.requiresRichInput)
        #expect(try await t.apply(TransformInput(text: "x AKIAIOSFODNN7EXAMPLE y")) == "x [REDACTED aws-access-key] y")
        #expect(try await t.apply(TransformInput(text: "nothing here")) == "nothing here")
    }
}
