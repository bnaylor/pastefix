import Testing
@testable import PastefixCore

@Suite struct SecretRedactorTests {
    func redact(_ s: String) -> String { SecretRedactor.redact(s, matches: SecretDetector.scan(s)) }
    @Test func tokensPerKind() {
        #expect(redact("k=AKIAIOSFODNN7EXAMPLE!") == "k=[REDACTED aws-access-key]!")
        #expect(redact("ghp_" + String(repeating: "a", count: 36)) == "[REDACTED github-token]")
    }
    @Test func urlKeepsUserAndHost() {
        #expect(redact("postgres://admin:s3cr3tPass@db.example.com/app") == "postgres://admin:[REDACTED]@db.example.com/app")
    }
    @Test func idempotent() {
        let once = redact("api_key: 9f8e7d6c5b4a39281706f5e4d3c2b1a0 and AKIAIOSFODNN7EXAMPLE")
        #expect(redact(once) == once && once == "api_key: [REDACTED credential] and [REDACTED aws-access-key]")
    }
    @Test func preservesSurroundingText() {
        let pem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        #expect(redact("before\n\(pem)\nafter") == "before\n[REDACTED private-key]\nafter")
    }
}
