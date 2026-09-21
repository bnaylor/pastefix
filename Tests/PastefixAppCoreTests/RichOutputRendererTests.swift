import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

@MainActor @Suite struct RichOutputRendererTests {
    @Test func rendersHTMLAndRTF() throws {
        let out = try RichOutputRenderer.render(markdown: "# Title\n\nsome **bold**")
        #expect(out.html.contains("<h1>Title</h1>") && out.html.contains("<strong>bold</strong>"))
        #expect(out.rtf.map { String(decoding: $0.prefix(5), as: UTF8.self) } == "{\\rtf")
    }

    // Privacy: AppKit's HTML importer is WebKit-backed and will fetch remote <img src="...">
    // resources while converting HTML to an attributed string. A Save must never turn into a
    // network request to whatever URL the Markdown named, so the RTF conversion path strips
    // <img> tags before handing HTML to the importer. The returned `html` (used for the .html
    // sibling file) keeps the images intact.
    @Test func stripsImagesBeforeRTFConversionButKeepsThemInHTML() throws {
        let out = try RichOutputRenderer.render(markdown: "![p](https://example.invalid/pixel.png)")
        #expect(out.html.contains("<img"))
        #expect(!RichOutputRenderer.htmlForRTF(out.html).contains("<img"))
    }
}
