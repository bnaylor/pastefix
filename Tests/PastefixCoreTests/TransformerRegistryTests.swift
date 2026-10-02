import Testing
import Foundation
@testable import PastefixCore

@Suite struct TransformerRegistryTests {
    /// Removed when the returned value goes away; keep it for the whole test (see `TemporaryDirectory`).
    private func makeTempDir() throws -> TemporaryDirectory { try TemporaryDirectory("pfx") }

    @Test func loadsBuiltinsInOrderWhenNoScripts() throws {
        let tmp = try makeTempDir(); let dir = tmp.url
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 400))
        let ids = reg.load().map(\.id)
        #expect(ids == [
            "builtin.richtoplain", "builtin.richtomarkdown", "builtin.markdowntorich",
            "builtin.transliterate", "builtin.wrapreflow", "builtin.whitespace", "builtin.claudepaste",
            "builtin.urlclean", "builtin.markdownlink",
            "builtin.case.camel", "builtin.case.snake", "builtin.case.kebab", "builtin.case.constant",
            "builtin.json.pretty", "builtin.json.minify", "builtin.json.escape",
            "builtin.base64.encode", "builtin.base64.decode", "builtin.url.encode", "builtin.url.decode",
            "builtin.html.encode", "builtin.html.decode", "builtin.jwt.decode", "builtin.qrmake",
            "builtin.color.hex", "builtin.color.rgb", "builtin.color.hsl", "builtin.color.swift",
            "builtin.redactsecrets",
            "builtin.stripimagemetadata",
            "builtin.extracttext",
            "builtin.crop",
            "builtin.redactselection", "builtin.blurselection",
            "builtin.rotateleft", "builtin.rotateright", "builtin.fliphorizontal", "builtin.flipvertical",
            "builtin.scalehalf", "builtin.fitwithin1920", "builtin.qrread",
        ])
    }

    @Test func discoversAndOrdersScriptsAmongBuiltins() throws {
        let tmp = try makeTempDir(); let dir = tmp.url
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
        let tmp = try makeTempDir(); let dir = tmp.url
        try "#!/bin/sh\n# pastefix: name = Off\n# pastefix: enabled = false\ncat".write(
            to: dir.appendingPathComponent("off.sh"), atomically: true, encoding: .utf8)
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        #expect(reg.load().contains { $0.name == "Off" } == false)
    }

    @Test func toleratesMissingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        #expect(reg.load().count == 41)   // built-ins only, no crash
    }

    @Test func scriptKindsSurfaceAsApplicableKinds() throws {
        let tmp = try makeTempDir(); let dir = tmp.url
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
        let tmp = try makeTempDir(); let dir = tmp.url
        let byID = Dictionary(uniqueKeysWithValues: TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load().map { ($0.id, $0.category) })
        #expect(byID["builtin.wrapreflow"] == TransformCategory.layout)
        #expect(byID["builtin.whitespace"] == TransformCategory.layout)
        #expect(byID["builtin.claudepaste"] == TransformCategory.layout)
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
        #expect(TransformCategory.builtinOrder == ["Layout", "Rich Text", "Characters", "URLs", "Case", "Data", "Colors", "Privacy", "Images", "Presets"])
    }

    @Test func richTextTransformsRegisteredInOrder() {
        let ids = TransformerRegistry(config: .init(scriptsDirectory: URL(fileURLWithPath: "/nonexistent"), wrapWidth: 80)).load().map(\.id)
        #expect(ids.prefix(3) == ["builtin.richtoplain", "builtin.richtomarkdown", "builtin.markdowntorich"])
    }

    @Test func scriptCategorySurfaces() throws {
        let tmp = try makeTempDir(); let dir = tmp.url
        try "#!/bin/sh\n# pastefix: name = Cat\n# pastefix: category = Text\ncat".write(to: dir.appendingPathComponent("cat.sh"), atomically: true, encoding: .utf8)
        try "// pastefix: name = NoCat\nfunction transform(t){return t;}".write(to: dir.appendingPathComponent("nocat.js"), atomically: true, encoding: .utf8)
        let loaded = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load()
        #expect(loaded.first { $0.name == "Cat" }?.category == "Text")
        #expect(loaded.first { $0.name == "NoCat" }?.category == nil)
    }

    @Test func presetsSitBetweenBuiltinsAndScripts() {
        // Mixed case on purpose: a case-sensitive `String.<` within the 900 band would return
        // Banana, Zebra, apple — every capital ahead of every lowercase.
        let z = RegexPreset(name: "Zebra", pattern: "z", replacement: "")
        let a = RegexPreset(name: "apple", pattern: "a", replacement: "")
        let b = RegexPreset(name: "Banana", pattern: "b", replacement: "")
        let cfg = RegistryConfig(scriptsDirectory: URL(fileURLWithPath: "/nonexistent"), wrapWidth: 80, presets: [z, a, b])
        let ids = TransformerRegistry(config: cfg).load().map(\.id)
        #expect(ids.suffix(3) == ["preset:\(a.id.uuidString)", "preset:\(b.id.uuidString)", "preset:\(z.id.uuidString)"])
        #expect(TransformCategory.builtinOrder.last == TransformCategory.presets)
    }
}
