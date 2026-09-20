import Testing
import Foundation
@testable import PastefixCore

@Suite struct TitleParsingTests {
    private func parse(_ html: String) -> String? { URLSessionTitleFetcher.parseTitle(data: Data(html.utf8)) }

    @Test func simple() { #expect(parse("<html><head><title>Hello</title></head></html>") == "Hello") }
    @Test func caseInsensitiveAndAttributes() { #expect(parse("<TITLE lang=\"en\">Hi</TITLE>") == "Hi") }
    @Test func missing() { #expect(parse("<html><body>no title</body></html>") == nil) }
    @Test func emptyIsNil() { #expect(parse("<title>   </title>") == nil) }
    @Test func whitespaceCollapsed() { #expect(parse("<title>\n  Two\n   lines \n</title>") == "Two lines") }
    @Test func entitiesDecoded() {
        #expect(parse("<title>A &amp; B &lt;C&gt; &quot;D&quot; &#39;E&#39; &#8212; &#x2014;</title>") == "A & B <C> \"D\" 'E' — —")
    }
    @Test func truncatedAtCapHasNoCloseTag() { #expect(parse("<title>Unfinished") == nil) }
    @Test func latin1Fallback() {
        let bytes: [UInt8] = Array("<title>caf".utf8) + [0xE9] + Array("</title>".utf8)   // é in ISO-8859-1
        #expect(URLSessionTitleFetcher.parseTitle(data: Data(bytes)) == "café")
    }
    @Test func doubleEncodedAmpersandDecodesOnce() { #expect(URLSessionTitleFetcher.decodeEntities("&amp;lt;") == "&lt;") }
    @Test func uppercaseHexEntity() { #expect(URLSessionTitleFetcher.decodeEntities("&#X2014;") == "—") }
    @Test func titlebarTagIsNotATitle() {
        #expect(parse("<titlebar>x</titlebar><title>Real</title>") == "Real")
    }
    @Test func utf8TruncatedMidCharacterStillDecodesAsUTF8() {
        var bytes = Array("<title>café — page</title><p>".utf8)
        bytes.append(contentsOf: [0xE2, 0x80])   // first two bytes of a 3-byte sequence, cut by the cap
        #expect(URLSessionTitleFetcher.parseTitle(data: Data(bytes)) == "café — page")
    }
}

/// Which URL `URLSessionTitleFetcher` actually requests. Host classification lives in
/// `FetchableHostTests`.
@Suite struct TitleFetchPolicyTests {
    private func fetchURL(_ s: String) -> String {
        URLSessionTitleFetcher.fetchURL(for: URL(string: s)!).absoluteString
    }
    @Test func httpIsFetchedOverHTTPS() {
        #expect(fetchURL("http://ex.com/a?b=1") == "https://ex.com/a?b=1")
    }
    @Test func httpsIsUnchanged() {
        #expect(fetchURL("https://ex.com/a?b=1") == "https://ex.com/a?b=1")
    }
    @Test func httpUpgradeKeepsFragmentAndPort() {
        #expect(fetchURL("http://ex.com:8080/a#f") == "https://ex.com:8080/a#f")
    }
    @Test func closeTitleSuffixDetectedCaseInsensitively() {
        #expect(URLSessionTitleFetcher.endsWithCloseTitle(Data("<title>Hi</TITLE>".utf8)))
        #expect(URLSessionTitleFetcher.endsWithCloseTitle(Data("</title>".utf8)))
        #expect(!URLSessionTitleFetcher.endsWithCloseTitle(Data("<title>Hi</title> more".utf8)))
        #expect(!URLSessionTitleFetcher.endsWithCloseTitle(Data("</tit".utf8)))
    }
}
