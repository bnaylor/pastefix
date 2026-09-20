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
    }
}
