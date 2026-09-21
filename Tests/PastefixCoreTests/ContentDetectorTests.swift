import Testing
import Foundation
@testable import PastefixCore

@Suite struct ContentDetectorTests {
    @Test func singleURL() { #expect(ContentDetector.detect("https://example.com") == [.url]) }
    @Test func urlInsideProse() { #expect(ContentDetector.detect("read https://example.com/a today") == [.url]) }
    @Test func bareWWW() { #expect(ContentDetector.detect("www.example.com") == [.url]) }
    @Test func mailtoIsNotURL() { #expect(ContentDetector.detect("someone@example.com") == []) }
    @Test func jsonObject() { #expect(ContentDetector.detect("{\"a\": 1}") == [.json]) }
    @Test func jsonArray() { #expect(ContentDetector.detect("[1, 2, 3]") == [.json]) }
    @Test func jsonWithLeadingWhitespace() { #expect(ContentDetector.detect("\n  {\"a\": [1]}\n") == [.json]) }
    @Test func jsonFragmentsRejected() {
        #expect(ContentDetector.detect("\"x\"") == [])
        #expect(ContentDetector.detect("42") == [])
    }
    @Test func braceThatIsNotJSON() { #expect(ContentDetector.detect("{ not json }") == []) }
    @Test func plainText() { #expect(ContentDetector.detect("hello world") == []) }
    @Test func empty() {
        #expect(ContentDetector.detect("") == [])
        #expect(ContentDetector.detect("   \n") == [])
    }
    @Test func bothKinds() {
        #expect(ContentDetector.detect("{\"link\": \"https://example.com\"}") == [.url, .json])
    }
    @Test func oversizeYieldsNothing() {
        let big = String(repeating: "https://example.com ", count: 60_000)   // ~1.2 MB
        #expect(big.utf8.count > ContentDetector.maxBytes)
        #expect(ContentDetector.detect(big) == [])
    }
    @Test func displayNames() {
        #expect(ContentKind.url.displayName == "URL")
        #expect(ContentKind.json.displayName == "JSON")
        #expect(ContentKind.color.displayName == "Color")
        #expect(ContentKind.jwt.displayName == "JWT")
        #expect(ContentKind.base64.displayName == "Base64")
        #expect(ContentKind.percentEncoded.displayName == "Percent-encoded")
        #expect(ContentKind.htmlEntities.displayName == "HTML entities")
        #expect(ContentKind.allCases.count == 7)
    }
    @Test func colorKind() {
        #expect(ContentDetector.detect("#ff0080") == [.color])
        #expect(ContentDetector.detect(" hsl(120 50% 50%) ") == [.color])
        #expect(ContentDetector.detect("use #fff for white") == [])
    }
    @Test func jwtKindExcludesBase64() {
        let t = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(ContentDetector.detect(t) == [.jwt])
    }
    @Test func base64Kind() {
        #expect(ContentDetector.detect("SGVsbG8sIHdvcmxkLiBUaGlzIGlzIHRleHQu") == [.base64])
        #expect(ContentDetector.detect("SGVsbG8sIHdv\ncmxkLiBUaGlzIGlzIHRleHQu") == [.base64])
        #expect(ContentDetector.detect("aMOpbGxv") == [])                    // too short
        #expect(ContentDetector.detect("internationalization") == [])       // decodes to junk
        #expect(ContentDetector.detect("AAAAAAAAAAAAAAAA") == [])            // NULs
    }
    @Test func percentEncodedKind() {
        #expect(ContentDetector.detect("see a%20b in prose") == [.percentEncoded])
        #expect(ContentDetector.detect("100% sure") == [])
    }
    @Test func htmlEntitiesKind() {
        #expect(ContentDetector.detect("Tom &amp; Jerry") == [.htmlEntities])
        #expect(ContentDetector.detect("caf&eacute; &#8212; &#x2014;") == [.htmlEntities])
        #expect(ContentDetector.detect("Tom & Jerry; fine") == [])
    }
    @Test func decodedJWTOutputIsNotReDetected() async throws {
        let t = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let out = try await JWTDecode().apply(.init(text: t))
        // The trailing comment lines break strict JSON; the detector sees the leading "{" and JSONSerialization fails → not json.
        // That is acceptable: document it. Assert only that it is not mis-detected as jwt/base64.
        #expect(ContentDetector.detect(out).isDisjoint(with: [.jwt, .base64]))
        #expect(!ContentDetector.detect(out).contains(.json))
    }
}
