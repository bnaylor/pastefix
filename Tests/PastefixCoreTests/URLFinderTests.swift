import Testing
import Foundation
@testable import PastefixCore

@Suite struct URLFinderTests {
    private func urls(_ text: String) -> [String] { URLFinder.find(in: text).map { $0.url.absoluteString } }
    private func originals(_ text: String) -> [String] { URLFinder.find(in: text).map { String($0.original) } }

    @Test func findsSingleURL() {
        #expect(urls("https://example.com/a?b=1") == ["https://example.com/a?b=1"])
    }

    @Test func excludesTrailingSentencePunctuation() {
        #expect(originals("See https://example.com/docs.") == ["https://example.com/docs"])
        #expect(originals("(https://example.com/x), then") == ["https://example.com/x"])
        #expect(originals("Really? https://example.com/y!") == ["https://example.com/y"])
    }

    @Test func keepsBalancedParensInPath() {
        let t = "https://en.wikipedia.org/wiki/Foo_(bar)"
        #expect(originals(t) == [t])
    }

    @Test func bareWWWHostGetsHTTPScheme() {
        let found = URLFinder.find(in: "go to www.example.com now")
        #expect(found.count == 1)
        #expect(found[0].url.absoluteString == "http://www.example.com")
        #expect(String(found[0].original) == "www.example.com")
    }

    @Test func ignoresMailtoAndNonHTTP() {
        #expect(urls("mail me at someone@example.com or ftp://x.y/z") == [])
    }

    @Test func multipleURLsInDocumentOrder() {
        let t = "a https://one.test/ b http://two.test/p c"
        #expect(urls(t) == ["https://one.test/", "http://two.test/p"])
    }

    @Test func rangesAreCorrectForReplacement() {
        var t = "x https://a.test/q y"
        let f = URLFinder.find(in: t)[0]
        t.replaceSubrange(f.range, with: "URL")
        #expect(t == "x URL y")
    }

    @Test func trimmingActuallyFiresAndURLMatchesOriginal() {
        // Cases where NSDataDetector itself includes the trailing character.
        let cases: [(String, String)] = [
            ("see https://example.com/a:", "https://example.com/a"),
            ("see https://example.com/a'", "https://example.com/a"),
            ("see https://example.com/a?", "https://example.com/a"),
            ("wrap (https://en.wikipedia.org/wiki/Foo_(bar))", "https://en.wikipedia.org/wiki/Foo_(bar)"),
        ]
        for (text, expected) in cases {
            let found = URLFinder.find(in: text)
            #expect(found.count == 1, "\(text)")
            #expect(String(found[0].original) == expected, "\(text)")
            #expect(found[0].url.absoluteString == expected, "\(text)")
        }
    }

    @Test func schemelessTrimmedMatchRebuildsURLFromTrimmedText() {
        let found = URLFinder.find(in: "see www.example.com/a?")
        #expect(found.count == 1)
        #expect(String(found[0].original) == "www.example.com/a")
        #expect(found[0].url.absoluteString == "http://www.example.com/a")
    }

    @Test func urlAlwaysEndsWithOriginal() {
        let text = "a https://x.test/p. b www.y.test/q, c (https://z.test/r) d https://w.test/s?k=v!"
        for f in URLFinder.find(in: text) {
            #expect(f.url.absoluteString.hasSuffix(String(f.original)), Comment(rawValue: String(f.original)))
        }
    }

    @Test func overCapReturnsNothing() {
        let unit = "https://example.com/p?x=1 "
        let atCap = String(repeating: unit, count: URLFinder.maxBytes / unit.utf8.count)
        #expect(atCap.utf8.count <= URLFinder.maxBytes)
        #expect(!URLFinder.find(in: atCap).isEmpty)
        let over = atCap + String(repeating: "a", count: URLFinder.maxBytes - atCap.utf8.count + 1)
        #expect(over.utf8.count > URLFinder.maxBytes)
        #expect(URLFinder.find(in: over).isEmpty)
    }

    @Test func cancelledTaskStopsEnumerationEarly() async {
        let text = String(repeating: "https://example.com/path?x=1 ", count: 8_000) // ~232 KB
        #expect(URLFinder.find(in: text).count == 8_000)
        let n = await Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return URLFinder.find(in: text).count
        }.value
        #expect(n < 8_000)
    }
}
