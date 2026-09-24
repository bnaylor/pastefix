import Testing
@testable import PastefixCore

@Suite struct SecretRedactorTests {
    func redact(_ s: String) -> String { SecretRedactor.redact(s, matches: SecretDetector.scan(s)) }
    @Test func tokensPerKind() {
        #expect(redact("k=AKIAIOSFODNN7EXAMPLE!") == "k=[REDACTED aws-access-key]!")
        #expect(redact("ghp_" + String(repeating: "a", count: 36)) == "[REDACTED github-token]")
    }
    @Test func urlKeepsUserAndHost() {
        // The token is typed here too: a bare "[REDACTED]" is itself a legal password
        // ([^\s/@]{1,128}), so the detector matched its own output and the badge never cleared.
        let out = redact("postgres://admin:s3cr3tPass@db.example.com/app")
        #expect(out == "postgres://admin:[REDACTED password]@db.example.com/app")
        #expect(SecretDetector.scan(out).isEmpty)
    }
    @Test func idempotent() {
        let once = redact("api_key: 9f8e7d6c5b4a39281706f5e4d3c2b1a0 and AKIAIOSFODNN7EXAMPLE")
        #expect(redact(once) == once && once == "api_key: [REDACTED credential] and [REDACTED aws-access-key]")
        // Stronger than string idempotence: the badge must actually clear.
        #expect(SecretDetector.scan(once).isEmpty)
        for s in ["postgres://admin:s3cr3tPass@db.example.com/app",
                  "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----",
                  "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
                  "{\"password\": \"9f8e7d6c5b4a39281706f5e4d3c2b1a0\"}",
                  "xoxb-1234567890-abcdefghij",
                  "sk-ant-api03-" + String(repeating: "aB3-x_9K7q", count: 6)] {
            #expect(SecretDetector.scan(redact(s)).isEmpty, "not quiescent: \(redact(s))")
        }
    }
    @Test func anthropicKeyGetsItsOwnToken() {
        // Must redact to "anthropic-key", not "openai-key": before the fix the OpenAI rule
        // claimed the same span and every sk-ant- key was mislabeled.
        let token = "sk-ant-api03-" + String(repeating: "aB3-x_9K7q", count: 6)
        #expect(redact(token) == "[REDACTED anthropic-key]")
        #expect(SecretDetector.scan(redact(token)).isEmpty)
    }
    @Test func preservesSurroundingText() {
        let pem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        #expect(redact("before\n\(pem)\nafter") == "before\n[REDACTED private-key]\nafter")
    }
    @Test func unsortedOrOverlappingMatchesDoNotTrap() {
        // redact is public API; a caller that hands back matches in another order (or a stale,
        // overlapping set) must get a sensible string, not a trap.
        let s = "api_key: 9f8e7d6c5b4a39281706f5e4d3c2b1a0 and AKIAIOSFODNN7EXAMPLE"
        let forward = SecretDetector.scan(s)
        #expect(forward.count == 2)
        #expect(SecretRedactor.redact(s, matches: forward.reversed()) == SecretRedactor.redact(s, matches: forward))
        // An overlapping duplicate of the first match is dropped rather than rewinding the cursor.
        let overlapping = [forward[0], SecretMatch(kind: .genericAssignment, range: forward[0].range), forward[1]]
        #expect(SecretRedactor.redact(s, matches: overlapping) == SecretRedactor.redact(s, matches: forward))
    }
}
