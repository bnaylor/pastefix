import Testing
@testable import PastefixCore

@Suite struct SecretDetectorTests {
    func kinds(_ s: String) -> [SecretKind] { SecretDetector.scan(s).map(\.kind) }
    func texts(_ s: String) -> [String] { SecretDetector.scan(s).map { String(s[$0.range]) } }

    @Test func awsAccessKey() {
        #expect(kinds("key AKIAIOSFODNN7EXAMPLE here") == [.awsAccessKey])
        #expect(kinds("AKIAIOSFODNN7EXAMPL") == [])                       // 15 chars
        #expect(kinds("xAKIAIOSFODNN7EXAMPLEx") == [])                    // no word boundary
    }
    @Test func awsSecretKey() {
        #expect(kinds("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY") == [.awsSecretKey])
        #expect(kinds("aws_secret_access_key = short") == [])
    }
    @Test func githubTokens() {
        #expect(kinds("ghp_" + String(repeating: "a", count: 36)) == [.githubToken])
        #expect(kinds("ghp_" + String(repeating: "a", count: 35)) == [])
        #expect(kinds("github_pat_" + String(repeating: "A1", count: 15)) == [.githubToken])
    }
    @Test func openAIKey() {
        #expect(kinds("OPENAI=sk-proj-" + String(repeating: "x9", count: 20)) == [.openAIKey])
        #expect(kinds("my task-list is sk-ipped") == [])
    }
    @Test func slackStripeGoogle() {
        #expect(kinds("xoxb-1234567890-abcdefghij") == [.slackToken])
        #expect(kinds("sk_live_" + String(repeating: "Ab1", count: 8)) == [.stripeKey])
        #expect(kinds("AIza" + String(repeating: "q", count: 35)) == [.googleAPIKey])
        #expect(kinds("AIza" + String(repeating: "q", count: 34)) == [])
    }
    @Test func privateKeyBlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nABC\n-----END RSA PRIVATE KEY-----"
        #expect(kinds(pem) == [.privateKey])
        #expect(texts("x \(pem) y") == [pem])
        #expect(kinds("-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----") == [])
    }
    @Test func jwt() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(kinds("Bearer \(jwt)") == [.jwt])
        #expect(kinds("a.b.c") == [])
    }
    @Test func passwordInURL() {
        let m = SecretDetector.scan("db: postgres://admin:s3cr3tPass@db.example.com:5432/app")
        #expect(m.map(\.kind) == [.passwordInURL])
        #expect(texts("postgres://admin:s3cr3tPass@db.example.com/app") == ["s3cr3tPass"])
        #expect(kinds("https://example.com/a:b@c") == [])     // no userinfo before host
    }
    @Test func genericAssignmentNeedsEntropy() {
        #expect(kinds("password=changeme-changeme") == [])
        #expect(kinds("api_key: \"9f8e7d6c5b4a39281706f5e4d3c2b1a0\"") == [.genericAssignment])
        #expect(kinds("token = null") == [])
        #expect(kinds("secret=aaaaaaaaaaaaaaaaaaaa") == [])
    }
    @Test func matchesAreSortedAndNonOverlapping() {
        let s = "AKIAIOSFODNN7EXAMPLE then api_key=9f8e7d6c5b4a39281706f5e4d3c2b1a0"
        let m = SecretDetector.scan(s)
        #expect(m.map(\.kind) == [.awsAccessKey, .genericAssignment])
        #expect(m[0].range.upperBound <= m[1].range.lowerBound)
    }
    @Test func boundedCost() {
        let line = String(repeating: "sk-abc ", count: 9_000)          // ~63 KB of near-misses
        let clock = ContinuousClock(); let t = clock.measure { _ = SecretDetector.scan(line) }
        #expect(t < .milliseconds(150))
        #expect(SecretDetector.scan(String(repeating: "a", count: SecretDetector.maxBytes + 1)).isEmpty)
    }
    @Test func tieBreakIsDeterministicByRuleOrder() {
        // "token=<jwt>" makes the jwt rule and the genericAssignment rule (whose value class
        // includes '.') match the identical (location, length) range. Rule declaration order
        // (jwt before genericAssignment) must decide the winner every time, regardless of
        // whatever order the underlying sort happens to visit equal elements in.
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let s = "token=\(jwt)"
        for _ in 0..<50 {
            let m = SecretDetector.scan(s)
            #expect(m.map(\.kind) == [.jwt])
            #expect(m.map { String(s[$0.range]) } == [jwt])
        }
    }
    @Test func entropy() {
        #expect(SecretDetector.entropy("aaaaaaaa") == 0)
        #expect(SecretDetector.entropy("9f8e7d6c5b4a39281706f5e4d3c2b1a0") > 3.5)
    }
}
