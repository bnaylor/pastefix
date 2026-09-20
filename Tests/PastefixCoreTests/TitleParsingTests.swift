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
}
