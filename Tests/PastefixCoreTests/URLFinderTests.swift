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
}
