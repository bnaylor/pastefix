import Testing
import Foundation
@testable import PastefixCore

@Suite struct TransformerRegistryTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadsBuiltinsInOrderWhenNoScripts() throws {
        let dir = try makeTempDir()
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 400))
        let ids = reg.load().map(\.id)
        #expect(ids == [
            "builtin.richtoplain", "builtin.richtomarkdown", "builtin.markdowntorich",
            "builtin.transliterate", "builtin.wrapreflow", "builtin.whitespace",
            "builtin.urlclean", "builtin.markdownlink",
            "builtin.case.camel", "builtin.case.snake", "builtin.case.kebab", "builtin.case.constant",
            "builtin.json.pretty", "builtin.json.minify", "builtin.json.escape",
            "builtin.base64.encode", "builtin.base64.decode", "builtin.url.encode", "builtin.url.decode",
            "builtin.html.encode", "builtin.html.decode", "builtin.jwt.decode",
            "builtin.color.hex", "builtin.color.rgb", "builtin.color.hsl", "builtin.color.swift",
            "builtin.redactsecrets",
        ])
    }

    @Test func discoversAndOrdersScriptsAmongBuiltins() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = Early\n# pastefix: order = 5\ncat".write(
            to: dir.appendingPathComponent("early.sh"), atomically: true, encoding: .utf8)
        try "/* pastefix: name = LateJS */\nfunction transform(t){return t;}".write(
            to: dir.appendingPathComponent("late.js"), atomically: true, encoding: .utf8)

        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        let names = reg.load().map(\.name)
        // Early(order 5) precedes built-ins (10-40); LateJS(order 1000 default) last.
        #expect(names.first == "Early")
        #expect(names.last == "LateJS")
    }

    @Test func excludesDisabledScripts() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = Off\n# pastefix: enabled = false\ncat".write(
            to: dir.appendingPathComponent("off.sh"), atomically: true, encoding: .utf8)
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        #expect(reg.load().contains { $0.name == "Off" } == false)
    }

    @Test func toleratesMissingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        #expect(reg.load().count == 27)   // built-ins only, no crash
    }

    @Test func scriptKindsSurfaceAsApplicableKinds() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = URLy\n# pastefix: kinds = url\ncat".write(
            to: dir.appendingPathComponent("urly.sh"), atomically: true, encoding: .utf8)
        try "// pastefix: name = Plain\nfunction transform(t){return t;}".write(
            to: dir.appendingPathComponent("plain.js"), atomically: true, encoding: .utf8)
        let loaded = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load()
        #expect(loaded.first { $0.name == "URLy" }?.applicableKinds == [.url])
        #expect(loaded.first { $0.name == "Plain" }?.applicableKinds == nil)
        #expect(loaded.first { $0.id == "builtin.whitespace" }?.applicableKinds == nil)
    }

    @Test func builtinsCarryTheirCategories() throws {
        let dir = try makeTempDir()
        let byID = Dictionary(uniqueKeysWithValues: TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load().map { ($0.id, $0.category) })
        #expect(byID["builtin.wrapreflow"] == TransformCategory.layout)
        #expect(byID["builtin.whitespace"] == TransformCategory.layout)
        #expect(byID["builtin.richtoplain"] == TransformCategory.richText)
        #expect(byID["builtin.richtomarkdown"] == TransformCategory.richText)
        #expect(byID["builtin.markdowntorich"] == TransformCategory.richText)
        #expect(byID["builtin.transliterate"] == TransformCategory.characters)
        #expect(byID["builtin.urlclean"] == TransformCategory.urls)
        #expect(byID["builtin.markdownlink"] == TransformCategory.urls)
        for style in ["camel", "snake", "kebab", "constant"] { #expect(byID["builtin.case.\(style)"] == TransformCategory.case) }
        let dataIDs = [
            "builtin.json.pretty", "builtin.json.minify", "builtin.json.escape",
            "builtin.base64.encode", "builtin.base64.decode", "builtin.url.encode", "builtin.url.decode",
            "builtin.html.encode", "builtin.html.decode", "builtin.jwt.decode",
        ]
        for id in dataIDs { #expect(byID[id] == TransformCategory.data) }
        let colorIDs = ["builtin.color.hex", "builtin.color.rgb", "builtin.color.hsl", "builtin.color.swift"]
        for id in colorIDs { #expect(byID[id] == TransformCategory.colors) }
        #expect(byID["builtin.redactsecrets"] == TransformCategory.privacy)
        #expect(TransformCategory.builtinOrder == ["Layout", "Rich Text", "Characters", "URLs", "Case", "Data", "Colors", "Privacy"])
    }

    @Test func richTextTransformsRegisteredInOrder() {
        let ids = TransformerRegistry(config: .init(scriptsDirectory: URL(fileURLWithPath: "/nonexistent"), wrapWidth: 80)).load().map(\.id)
        #expect(ids.prefix(3) == ["builtin.richtoplain", "builtin.richtomarkdown", "builtin.markdowntorich"])
    }

    @Test func scriptCategorySurfaces() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = Cat\n# pastefix: category = Text\ncat".write(to: dir.appendingPathComponent("cat.sh"), atomically: true, encoding: .utf8)
        try "// pastefix: name = NoCat\nfunction transform(t){return t;}".write(to: dir.appendingPathComponent("nocat.js"), atomically: true, encoding: .utf8)
        let loaded = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load()
        #expect(loaded.first { $0.name == "Cat" }?.category == "Text")
        #expect(loaded.first { $0.name == "NoCat" }?.category == nil)
    }
}
