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
        #expect(ids == ["builtin.richtoplain", "builtin.transliterate", "builtin.wrapreflow", "builtin.whitespace"])
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
        #expect(reg.load().count == 4)   // built-ins only, no crash
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
}
