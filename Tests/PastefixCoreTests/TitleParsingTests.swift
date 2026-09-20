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

/// Pre-request policy for `URLSessionTitleFetcher`: which URL is actually fetched, and
/// which hosts are never contacted at all.
@Suite struct TitleFetchPolicyTests {
    private func fetchURL(_ s: String) -> String {
        URLSessionTitleFetcher.fetchURL(for: URL(string: s)!).absoluteString
    }
    private func fetchable(_ s: String) -> Bool {
        URLSessionTitleFetcher.isFetchable(URL(string: s)!)
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
    @Test func publicHostIsFetchable() {
        #expect(fetchable("https://example.com/a"))
        #expect(fetchable("https://8.8.8.8/a"))
        #expect(fetchable("https://172.32.0.1/a"))
        #expect(fetchable("https://11.0.0.1/a"))
    }
    @Test func localhostIsNotFetchable() {
        #expect(!fetchable("http://localhost/a"))
        #expect(!fetchable("http://LOCALHOST:3000/a"))
    }
    @Test func dotLocalIsNotFetchable() {
        #expect(!fetchable("http://mac.local/a"))
        #expect(!fetchable("http://Mac.LOCAL/a"))
    }
    @Test func loopbackIsNotFetchable() {
        #expect(!fetchable("http://127.0.0.1/a"))
        #expect(!fetchable("http://127.1.2.3/a"))
        #expect(!fetchable("http://[::1]/a"))
    }
    @Test func privateRangesAreNotFetchable() {
        #expect(!fetchable("http://10.1.2.3/a"))
        #expect(!fetchable("http://172.16.0.1/a"))
        #expect(!fetchable("http://172.31.255.254/a"))
        #expect(!fetchable("http://192.168.1.1/a"))
        #expect(!fetchable("http://169.254.1.1/a"))
    }
    @Test func closeTitleSuffixDetectedCaseInsensitively() {
        #expect(URLSessionTitleFetcher.endsWithCloseTitle(Data("<title>Hi</TITLE>".utf8)))
        #expect(URLSessionTitleFetcher.endsWithCloseTitle(Data("</title>".utf8)))
        #expect(!URLSessionTitleFetcher.endsWithCloseTitle(Data("<title>Hi</title> more".utf8)))
        #expect(!URLSessionTitleFetcher.endsWithCloseTitle(Data("</tit".utf8)))
    }
    @Test func emptyHostIsNotFetchable() {
        #expect(!URLSessionTitleFetcher.isFetchable(URL(string: "file:///tmp/x.html")!))
    }
}
