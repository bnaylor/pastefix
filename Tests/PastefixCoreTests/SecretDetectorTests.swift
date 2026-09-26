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
        // Anthropic's more specific "sk-ant-" prefix must not be swallowed by the OpenAI rule.
        #expect(kinds("sk-proj-" + String(repeating: "a", count: 48)) == [.openAIKey])
        #expect(kinds("sk-" + String(repeating: "a", count: 48)) == [.openAIKey])
    }
    @Test func anthropicKey() {
        // sk-ant-api03- plus 60 mixed alnum/-/_ characters: the OpenAI rule's class matches the
        // identical span (its greedy run swallows "ant-api03-…" too), so this is a same-range tie
        // broken by SecretKind declaration order, not rule-list position — see the comment above
        // the anthropicKey rule.
        let token = "sk-ant-api03-" + String(repeating: "aB3-x_9K7q", count: 6)   // 60 mixed chars
        #expect(kinds("key: \(token) end") == [.anthropicKey])
        #expect(texts("key: \(token) end") == [token])
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
        // An unlabelled block and a labelled one both need their own END marker; a BEGIN whose
        // END carries a different label is not a block.
        #expect(kinds("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----") == [.privateKey])
        #expect(kinds("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END EC PRIVATE KEY-----") == [])
        #expect(kinds("-----BEGIN RSA PRIVATE KEY-----\nabc\n") == [])          // no END at all
    }
    @Test func privateKeyBodyLimit() {
        // The END marker is looked for in a bounded window after BEGIN, so a body longer than
        // `maxPEMBodyLength` is not matched at all (not truncated — missed). Documented limit.
        func pem(body: Int) -> String {
            "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "A", count: body) + "\n-----END RSA PRIVATE KEY-----"
        }
        #expect(kinds(pem(body: 15_360)) == [.privateKey])                     // 15 KB body: matched
        #expect(kinds(pem(body: 20_480)) == [])                                // 20 KB body: missed
    }
    @Test func jwt() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(kinds("Bearer \(jwt)") == [.jwt])
        #expect(kinds("a.b.c") == [])
        #expect(texts("<\(jwt)>") == [jwt])                                    // bracket-delimited
        #expect(texts("Here it is: \(jwt).") == [jwt])                         // sentence-final dot trimmed
        // Delimiting on every non-JWT character (not just whitespace) keeps the two shapes the
        // old regex found and a whitespace-only split would lose.
        #expect(texts("https://example.com/cb?id_token=\(jwt)&state=1") == [jwt])
        #expect(kinds("aaaaaaaa.bbbbbbbb.cccccccc") == [])                     // shape only, not a JWT
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
    @Test func genericAssignmentSeesQuotedKeys() {
        // JSON/YAML/PHP credential blobs are the commonest way a secret reaches the clipboard;
        // an unquoted-key-only pattern was silent on every one of them.
        let hex = "9f8e7d6c5b4a39281706f5e4d3c2b1a0"
        #expect(kinds("{\"password\": \"\(hex)\"}") == [.genericAssignment])
        #expect(kinds("\"api_key\": \"\(hex)\"") == [.genericAssignment])
        #expect(kinds("'password' => '\(hex)'") == [.genericAssignment])
        #expect(texts("{\"password\": \"\(hex)\"}") == [hex])       // the value only
        #expect(kinds("{\"password\": \"changeme-changeme\"}") == [])   // still entropy-gated
    }
    @Test func genericAssignmentValueLengthIsTerminated() {
        // A value longer than the class bound must fail outright. Matching its first 256
        // characters would redact a prefix, leave the tail in the buffer, and clear the badge.
        let unit = "aB3dE5gH7jK9mN1pQ2rS4tU6vW8xY0zA"                          // 32 chars
        #expect(kinds("api_key=" + String(repeating: unit, count: 8)) == [.genericAssignment])   // 256
        #expect(kinds("api_key=" + String(repeating: unit, count: 10)) == [])                    // 320
    }
    @Test func matchesAreSortedAndNonOverlapping() {
        let s = "AKIAIOSFODNN7EXAMPLE then api_key=9f8e7d6c5b4a39281706f5e4d3c2b1a0"
        let m = SecretDetector.scan(s)
        #expect(m.map(\.kind) == [.awsAccessKey, .genericAssignment])
        #expect(m[0].range.upperBound <= m[1].range.lowerBound)
    }
    @Test func boundedCost() {
        let clock = ContinuousClock()
        // Every shape below is sized to the cap and is one the scanner could plausibly be handed;
        // the first four are the ones that used to backtrack for seconds on the main actor.
        let unbrokenBase64URL = String(repeating: "aB9_x-Zq", count: 32_768)                  // 256 KB, one run
        let dottedBase64URL = String(repeating: String(repeating: "aB9_x-Zq", count: 4) + "." +
                                     String(repeating: "Qz7-y_Wb", count: 4) + "." +
                                     String(repeating: "Lm4_p-Kt", count: 4) + " ", count: 2_647)
        let unterminatedPEM = String(repeating: "-----BEGIN RSA PRIVATE KEY-----\n", count: 8_192)
        let maximalSlack = String(repeating: "xoxb-" + String(repeating: "a", count: 200) + " ", count: 1_272)
        // Minimal three-segment tokens whose first character survives the JWT header pre-filter:
        // ~9 700 candidates that each reach the base64 decode, the worst shape for the tokeniser.
        let minimalJWTCandidates = String(repeating: "eyJhbGciOiJI.bbbbbbbb.cccccccc ", count: 8_456)
        let nearMisses = String(repeating: "sk-abc ", count: 9_000)                           // ~63 KB
        for (label, s) in [("unbroken base64url", unbrokenBase64URL), ("dotted base64url", dottedBase64URL),
                           ("minimal JWT candidates", minimalJWTCandidates),
                           ("unterminated PEM", unterminatedPEM), ("maximal slack", maximalSlack),
                           ("sk- near misses", nearMisses)] {
            #expect(s.utf8.count <= SecretDetector.maxBytes, "\(label) must not be rejected by the size guard")
            let t = clock.measure { _ = SecretDetector.scan(s) }
            // 1 s, not the 150 ms budget: this is wall-clock time measured while 48 other suites
            // run in parallel, and at 150 ms it failed the full suite (166 ms) while passing in
            // isolation. The regressions it exists to catch — the JWT regex at 10 s per 256 KB,
            // the lazy PEM window at 3 s per MB — are two orders of magnitude clear of 1 s, so
            // the bound still catches them without being a coin toss. Every adversarial shape is
            // kept; the shapes are the test, the stopwatch is only the alarm.
            #expect(t < .seconds(1), "\(label) took \(t)")
        }
        // The guard, not the content: an oversize buffer holding a real key must still be empty.
        let oversize = String(repeating: "a", count: SecretDetector.maxBytes) + " AKIAIOSFODNN7EXAMPLE"
        #expect(oversize.utf8.count > SecretDetector.maxBytes)
        #expect(SecretDetector.scan(oversize).isEmpty)
        #expect(SecretDetector.scan("AKIAIOSFODNN7EXAMPLE") == SecretDetector.scan("AKIAIOSFODNN7EXAMPLE"))
        #expect(!SecretDetector.scan("AKIAIOSFODNN7EXAMPLE").isEmpty)          // same key, under the cap
    }
    /// `scanIgnoringSizeCap` was extracted out of `scan` for the upload path, and the claim was
    /// that `scan` is byte-for-byte unchanged — a claim that until now rested on reading the
    /// code. This is the assertion: for a buffer *under* the cap the two entry points must agree
    /// exactly, because the cap is supposed to be the only difference between them.
    ///
    /// Not two empty arrays agreeing: the fixture carries seven kinds, two sites where two rules
    /// match the same text (so the location/length/kind tie-break runs), and three matches
    /// separated only by a single space (so the `r.location >= cursor` sweep runs).
    @Test("under the cap, scan and scanIgnoringSizeCap agree exactly")
    func cappedAndUncappedAgreeUnderTheCap() {
        let fixture = """
        db_url=postgres://svc:Tr0ub4dor&3xKcd-9zQ@db.internal:5432/app
        password: hunter2!SuperSecret99
        access_key = AKIAIOSFODNN7EXAMPLE
        AKIAIOSFODNN7EXAMPLE AKIAIOSFODNN7EXAMPLE
        token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk
        ghp_1234567890abcdefghijklmnopqrstuvwxyz sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789
        -----BEGIN RSA PRIVATE KEY-----
        MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu
        -----END RSA PRIVATE KEY-----
        """
        #expect(fixture.utf8.count <= SecretDetector.maxBytes)

        let capped = SecretDetector.scan(fixture)
        let uncapped = SecretDetector.scanIgnoringSizeCap(fixture)
        #expect(capped == uncapped)

        // The fixture is doing the work it claims to: several kinds, and the overlap sites
        // resolved to one match each rather than two stacked on the same bytes.
        #expect(Set(capped.map(\.kind)).count >= 6)
        #expect(capped.filter { $0.kind == .awsAccessKey }.count == 3)
        #expect(capped.filter { fixture[$0.range].hasPrefix("eyJ") }.count == 1)
        // `access_key = AKIA…` is matched by both `awsAccessKey` and `genericAssignment`; the
        // dedup keeps one, and both entry points keep the same one.
        #expect(capped.filter { fixture[$0.range] == "AKIAIOSFODNN7EXAMPLE" }.allSatisfy { $0.kind == .awsAccessKey })

        // The output invariant the sweep is there to produce: ascending and non-overlapping.
        for (earlier, later) in zip(capped, capped.dropFirst()) {
            #expect(earlier.range.upperBound <= later.range.lowerBound)
        }
    }

    @Test func manyRealJWTsAreAllFound() {
        // The JWT validation budget is a cost cap, not a content cap: a buffer packed with real
        // JWTs stays well under it, because a real one runs to hundreds of characters.
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let buffer = String(repeating: jwt + "\n", count: 500)
        #expect(buffer.utf8.count <= SecretDetector.maxBytes)
        let m = SecretDetector.scan(buffer)
        #expect(m.count == 500)
        #expect(m.allSatisfy { $0.kind == .jwt })
    }
    @Test func weakCandidatesNeverHideARealJWT() {
        // Two halves of the same fix. (a) The pre-filter now rejects dotted source-code
        // identifiers outright: "IConfiguration" cannot close a JSON object. (b) Even for tokens
        // that do survive it, the validation budget bounds validations only — the walk always
        // completes — so a JWT after 4 096 junk candidates is still found. An earlier version
        // stopped the walk and missed it.
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        // "IAAAAAAAAAJ9" decodes to a space, NULs and a closing brace, so it clears every cheap
        // check and is only rejected by the full JSON parse — the most expensive junk there is.
        let weakUnit = "IAAAAAAAAAJ9.e30.abc "
        for (label, noise) in [("source-code identifiers", String(repeating: "IConfiguration.Bind.Extensions\n", count: 6_606)),
                               ("budget-exhausting junk", String(repeating: weakUnit, count: 5_000))] {
            let buffer = noise + jwt
            #expect(buffer.utf8.count <= SecretDetector.maxBytes)
            let m = SecretDetector.scan(buffer)
            #expect(m.map(\.kind) == [.jwt], "\(label): \(m.count) matches")
            #expect(m.map { String(buffer[$0.range]) } == [jwt])
            let t = ContinuousClock().measure { _ = SecretDetector.scan(buffer) }
            #expect(t < .seconds(1), "\(label) took \(t)")     // load-tolerant, as in `boundedCost`
        }
        #expect(5_000 > SecretDetector.maxWeakJWTCandidates)     // the budget really is exhausted
    }
    @Test func minimalPayloadSegmentIsAccepted() {
        // `e30` is base64url for `{}`, a perfectly real (if empty) payload, so the pre-filter's
        // payload floor is what JWTDecoder.split accepts — two characters — not an invented four.
        let jwt = "eyJhbGciOiJIUzI1NiJ9.e30.abcd"
        #expect(kinds(jwt) == [.jwt])
        #expect(texts("header \(jwt) trailer") == [jwt])
    }
    @Test func tieBreakIsDeterministicByRuleOrder() {
        // "token=<jwt>" makes the jwt rule and the genericAssignment rule (whose value class
        // includes '.') match the identical (location, length) range. SecretKind declaration
        // order (jwt before genericAssignment) must decide the winner every time, regardless of
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
    @Test func entropyBarIsAlphabetNormalised() {
        // Normalising by log2(length) made the bar HARDER the longer the value, so detection fell
        // monotonically as the secret got stronger: measured over 200 random samples per length,
        // 16-hex cleared 173/200 and 40-, 48- and 64-hex cleared 0/200 — a 256-bit key scanned
        // clean. Normalising by the observed alphabet is length-independent; these fixed random
        // hex literals are one sample each of lengths that used to be invisible, and under the
        // alphabet bar 2 000/2 000 random hex values clear it at every one of these lengths.
        for hex in ["eee65f53e9421ce5",                                                  // 16
                    "0211670eae679f02e8d28a79",                                          // 24
                    "023c39c200661fccd268a29a0d347301",                                  // 32
                    "ef56e64dc3cd6089065c3146e80a9c222670bbe4",                          // 40
                    "f4c54977656cf2d133187c8df95247f2866028de71159b42",                  // 48
                    "b4ea410fb9102f29a422eb14ab2f2d0f0cc022238daceee2092f073ff80b9465"] { // 64
            #expect(kinds("api_key = \(hex)") == [.genericAssignment], "\(hex.count)-hex missed")
        }
        // Quiet, and by which rule: the alphabet bar is loose on its own (every placeholder below
        // clears it), so the digit requirement and the distinct-character floor are what silence
        // these. Pinning the mechanism keeps a future tweak honest.
        for placeholder in ["changeme-changeme", "your-token-here-xx", "please-change-me-now",
                            "example-value-goes-here", "/var/run/secrets/tok"] {
            let hasDigit = placeholder.contains(where: \.isNumber)
            #expect(!hasDigit)                                                    // no digit
            #expect(kinds("token = \(placeholder)") == [], "\(placeholder) fired")
        }
        #expect(SecretDetector.distinctCharacters("aaaaaaaa1aaaaaaa") < SecretDetector.minDistinctCharacters)
        #expect(SecretDetector.normalisedEntropy("aaaaaaaa1aaaaaaa") < SecretDetector.minNormalisedEntropy)
        #expect(kinds("token = aaaaaaaa1aaaaaaa") == [])
        // Four distinct characters, but well mixed: 0.91 of its own alphabet's maximum. Only the
        // distinct-character floor stops this one.
        #expect(SecretDetector.normalisedEntropy("abcabcabcabcabc1") >= SecretDetector.minNormalisedEntropy)
        #expect(SecretDetector.distinctCharacters("abcabcabcabcabc1") < SecretDetector.minDistinctCharacters)
        #expect(kinds("token = abcabcabcabcabc1") == [])
        #expect(kinds("token = null") == [])
        #expect(kinds("api_key: \"9f8e7d6c5b4a39281706f5e4d3c2b1a0\"") == [.genericAssignment])
        #expect(kinds("secret=aaaaaaaaaaaaaaaaaaaa") == [])
        // A UUID scores 3.39 bits/char — below `changeme-changeme` — because 36 characters is a
        // poor sample of a 122-bit secret, so it is accepted on shape. It only gets here behind a
        // credential key name; a bare UUID stays quiet.
        #expect(kinds("api_key=550e8400-e29b-41d4-a716-446655440000") == [.genericAssignment])
        #expect(kinds("id: 550e8400-e29b-41d4-a716-446655440000") == [])
        #expect(SecretDetector.normalisedEntropy("a3f9c1e7b2d84f06") >= SecretDetector.minNormalisedEntropy)
    }
    @Test func genericAssignmentSeesPunctuationInValues() {
        // The commonest human password shape. An allow-list value class missed both of these
        // outright — `&` and `!` sat outside it — which is much broader than the disclosed
        // "letters-only values are not flagged" limit.
        #expect(kinds("{\"password\": \"Tr0ub4dor&3xKcd-9zQ\"}") == [.genericAssignment])
        #expect(texts("{\"password\": \"Tr0ub4dor&3xKcd-9zQ\"}") == ["Tr0ub4dor&3xKcd-9zQ"])   // value only
        #expect(kinds("password: hunter2!SuperSecret99") == [.genericAssignment])
        // One trailing full stop is the sentence's, not the token's.
        #expect(texts("token: ABCD1234EFGH5678.") == ["ABCD1234EFGH5678"])
        let out = SecretRedactor.redact("token: ABCD1234EFGH5678.", matches: SecretDetector.scan("token: ABCD1234EFGH5678."))
        #expect(out == "token: [REDACTED credential].")
    }
    @Test func vendorRulesDoNotMatchMidToken() {
        // `\b` succeeds before `-`, so an over-long hyphenated token matched a prefix: redaction
        // left the tail in the buffer and the rescan came back clean. The lookahead makes the
        // whole match fail instead — no badge is honest, a partial redaction is not.
        let longTail = String(repeating: "aB9cD8eF7gH6iJ5kL4mN3oP2qR1sT0uV", count: 10)     // 320 chars
        #expect(kinds("xoxb-" + longTail) == [])
        #expect(kinds("sk-" + longTail) == [])
        #expect(kinds("sk_live_" + longTail) == [])
        // A 50-character AWS secret value: 40 characters of it used to redact, leaving 10 behind.
        #expect(kinds("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEYabcdefghij") == [])
        // Canonical lengths are untouched.
        #expect(kinds("xoxb-1234567890-abcdefghij") == [.slackToken])
        #expect(kinds("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY") == [.awsSecretKey])
        #expect(kinds("ghp_" + String(repeating: "a", count: 36)) == [.githubToken])
        #expect(kinds("AIza" + String(repeating: "q", count: 35)) == [.googleAPIKey])
        #expect(kinds("OPENAI=sk-proj-" + String(repeating: "x9", count: 20)) == [.openAIKey])
        #expect(kinds("sk_live_" + String(repeating: "Ab1", count: 8)) == [.stripeKey])
    }
    @Test func isScannableMarksTheUnexaminedBuffer() {
        // The scan cap is also a claim cap: `scan` returning [] above it is the absence of a
        // scan, and `isScannable` is how every caller tells that apart from a clean result.
        let oversize = String(repeating: "a", count: SecretDetector.maxBytes) + " AKIAIOSFODNN7EXAMPLE"
        #expect(!SecretDetector.isScannable(oversize))
        #expect(SecretDetector.scan(oversize).isEmpty)
        #expect(SecretDetector.isScannable(String(repeating: "a", count: SecretDetector.maxBytes)))
        #expect(SecretDetector.isScannable("AKIAIOSFODNN7EXAMPLE") && !SecretDetector.scan("AKIAIOSFODNN7EXAMPLE").isEmpty)
        #expect(SecretDetector.isScannable(""))
    }
    @Test func genericAssignmentValueNeedsADigit() {
        // Placeholders and paths score as "random" on normalised Shannon entropy — every one of
        // these cleared the bar — so a credential value must also carry a digit.
        for placeholder in ["your-token-here-xx", "please-change-me-now", "example-value-goes-here", "/var/run/secrets/tok"] {
            #expect(SecretDetector.normalisedEntropy(placeholder) >= SecretDetector.minNormalisedEntropy,
                    "\(placeholder) is meant to be a near-miss the entropy bar alone lets through")
            #expect(kinds("token=\(placeholder)") == [], "\(placeholder) fired")
        }
        // Accepted miss: a letters-only key (~3% of real ones) is the price of that rule.
        #expect(kinds("token=abcdefghijklmnopqrstuvwx") == [])
        // The values that matter are unaffected.
        #expect(kinds("api_key=a3f9c1e7b2d84f06") == [.genericAssignment])
        #expect(kinds("api_key: \"9f8e7d6c5b4a39281706f5e4d3c2b1a0\"") == [.genericAssignment])
        #expect(kinds("api_key=550e8400-e29b-41d4-a716-446655440000") == [.genericAssignment])
    }
}
