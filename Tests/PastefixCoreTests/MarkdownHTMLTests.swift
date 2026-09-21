import Testing
@testable import PastefixCore

@Suite struct MarkdownHTMLTests {
    func r(_ s: String) throws -> String { try MarkdownHTML.render(s) }

    @Test func headings() throws {
        #expect(try r("# One") == "<h1>One</h1>")
        #expect(try r("### Three") == "<h3>Three</h3>")
    }

    @Test func inlineStyles() throws {
        #expect(try r("**b** and *i* and `c` and ~~s~~") == "<p><strong>b</strong> and <em>i</em> and <code>c</code> and <del>s</del></p>")
    }

    @Test func linkAndImage() throws {
        #expect(try r("[site](https://x.y/?a=1&b=2)") == "<p><a href=\"https://x.y/?a=1&amp;b=2\">site</a></p>")
        #expect(try r("![alt text](https://x.y/i.png)") == "<p><img src=\"https://x.y/i.png\" alt=\"alt text\"></p>")
        // Foundation gives an alt-less image U+FFFC as its run text; that must not reach `alt`.
        #expect(try r("![](https://x.y/i.png)") == "<p><img src=\"https://x.y/i.png\" alt=\"\"></p>")
    }

    @Test func tightLists() throws {
        #expect(try r("- a\n- b") == "<ul><li>a</li><li>b</li></ul>")
        #expect(try r("1. a\n2. b") == "<ol><li>a</li><li>b</li></ol>")
    }

    @Test func nestedList() throws {
        #expect(try r("- a\n  - b\n- c") == "<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>")
    }

    @Test func fencedCodeEscapes() throws {
        #expect(try r("```swift\nlet a = 1 < 2\n```") == "<pre><code class=\"language-swift\">let a = 1 &lt; 2\n</code></pre>")
        #expect(try r("    indented\n") == "<pre><code>indented\n</code></pre>")
    }

    @Test func blockQuoteAndRule() throws {
        #expect(try r("> quoted") == "<blockquote><p>quoted</p></blockquote>")
        #expect(try r("a\n\n***\n\nb") == "<p>a</p><hr><p>b</p>")
    }

    @Test func table() throws {
        #expect(try r("| h1 | h2 |\n|---|---|\n| c1 | c2 |") == "<table><thead><tr><th>h1</th><th>h2</th></tr></thead><tbody><tr><td>c1</td><td>c2</td></tr></tbody></table>")
    }

    @Test func breaksAndEscaping() throws {
        #expect(try r("line one  \nline two") == "<p>line one<br>line two</p>")
        #expect(try r("a & b <script>") == "<p>a &amp; b &lt;script&gt;</p>")
    }

    @Test func softBreak() throws {
        #expect(try r("line one\nline two") == "<p>line one\nline two</p>")
    }

    /// Destinations that must never reach an emitted `href`/`src`.
    static let unsafeDestinations = [
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        "data:text/html;base64,PHNjcmlwdD4=",
        "file:///etc/passwd",
        "vbscript:msgbox(1)",
    ]

    @Test(arguments: unsafeDestinations)
    func linkSchemeAllowlist(_ destination: String) throws {
        let out = try r("[a & <b>](\(destination))")
        #expect(!out.contains("<a"))
        #expect(out == "<p>a &amp; &lt;b&gt;</p>")
    }

    @Test(arguments: unsafeDestinations)
    func imageSchemeAllowlist(_ destination: String) throws {
        let out = try r("![a & <b>](\(destination))")
        #expect(!out.contains("<img"))
        #expect(out == "<p>a &amp; &lt;b&gt;</p>")
    }

    @Test func referenceDefinitionSchemeAllowlist() throws {
        #expect(try r("[a][1]\n\n[1]: javascript:alert(2)") == "<p>a</p>")
    }

    /// A protocol-relative destination has no scheme *here*, so it slips past a scheme
    /// allowlist, but it inherits one wherever the fragment is pasted and resolves to a live
    /// cross-origin request. It is refused rather than waved through with `/path` and `#frag`.
    @Test func protocolRelativeDestinationsAreRejected() throws {
        #expect(try r("[x](//evil.example/p)") == "<p>x</p>")
        #expect(try r("![x](//evil.example/i.png)") == "<p>x</p>")
        #expect(try r("[x](/local)") == "<p><a href=\"/local\">x</a></p>")
    }

    @Test func allowedSchemesSurvive() throws {
        #expect(try r("[a](mailto:x@y.z)") == "<p><a href=\"mailto:x@y.z\">a</a></p>")
        #expect(try r("[a](/relative/path)") == "<p><a href=\"/relative/path\">a</a></p>")
        #expect(try r("[a](#frag)") == "<p><a href=\"#frag\">a</a></p>")
        #expect(try r("[a](HTTPS://X.Y)") == "<p><a href=\"HTTPS://X.Y\">a</a></p>")
    }

    @Test func partiallyMalformedStillRenders() throws {
        let out = try r("# ok\n\n[unclosed link(\n\n**bold")
        #expect(out.hasPrefix("<h1>ok</h1>") && out.contains("<p>"))
    }
}
