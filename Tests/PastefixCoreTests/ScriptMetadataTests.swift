import Testing
@testable import PastefixCore

@Suite struct ScriptMetadataTests {
    @Test func parsesShellStyleHeader() {
        let src = """
        #!/bin/sh
        # pastefix: name = Rot13
        # pastefix: enabled = false
        # pastefix: order = 50
        tr a-z n-za-m
        """
        let md = ScriptMetadata.parse(src)
        #expect(md == ScriptMetadata(name: "Rot13", enabled: false, order: 50))
    }

    @Test func parsesBlockCommentStyleHeader() {
        let src = """
        /* pastefix: name = Upper */
        function transform(t) { return t.toUpperCase(); }
        """
        let md = ScriptMetadata.parse(src)
        #expect(md.name == "Upper")
        #expect(md.enabled == true)   // default
        #expect(md.order == nil)
    }

    @Test func defaultsWhenNoMetadata() {
        let md = ScriptMetadata.parse("echo hi")
        #expect(md == ScriptMetadata(name: nil, enabled: true, order: nil))
    }

    @Test func ignoresMalformedAndUnknownKeys() {
        let src = """
        # pastefix: name = Good
        # pastefix: bogus
        # pastefix: unknown = x
        # pastefix: order = notanumber
        """
        let md = ScriptMetadata.parse(src)
        #expect(md.name == "Good")
        #expect(md.order == nil)      // "notanumber" fails Int() → left nil
    }

    @Test func onlyScansFirstThirtyLines() {
        let padding = String(repeating: "x\n", count: 40)
        let md = ScriptMetadata.parse(padding + "# pastefix: name = TooLate")
        #expect(md.name == nil)
    }

    @Test func parsesKinds() {
        #expect(ScriptMetadata.parse("# pastefix: kinds = url").kinds == [.url])
        #expect(ScriptMetadata.parse("# pastefix: kinds = URL, json").kinds == [.url, .json])
        #expect(ScriptMetadata.parse("# pastefix: kinds = json,unknown").kinds == [.json])
        #expect(ScriptMetadata.parse("# pastefix: kinds = bogus").kinds == nil)
        #expect(ScriptMetadata.parse("# pastefix: name = X").kinds == nil)
    }

    @Test func parsesCategory() {
        #expect(ScriptMetadata.parse("# pastefix: category = Text").category == "Text")
        #expect(ScriptMetadata.parse("# pastefix: category =   Spaced Out  ").category == "Spaced Out")
        #expect(ScriptMetadata.parse("# pastefix: category =").category == nil)
        #expect(ScriptMetadata.parse("# pastefix: name = X").category == nil)
    }
}
