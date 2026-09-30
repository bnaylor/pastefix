import Testing
import Foundation

/// The helper that stops test fixtures leaking into $TMPDIR: its folder is removed when the value
/// goes away, including when a test throws part-way (no `defer` to forget).
@Suite struct TemporaryDirectoryTests {
    @Test func createdWithThePrefixAndRemovedWithItsContents() throws {
        var path = ""
        do {
            let tmp = try TemporaryDirectory("pfx-tmptest")
            path = tmp.url.path
            #expect(tmp.url.lastPathComponent.hasPrefix("pfx-tmptest-"))
            #expect(FileManager.default.fileExists(atPath: path))
            try Data("x".utf8).write(to: tmp.url.appendingPathComponent("file"))
        }
        #expect(!FileManager.default.fileExists(atPath: path), "left behind in $TMPDIR")
    }

    @Test func removedWhenTheTestThrows() throws {
        var path = ""
        struct Boom: Error {}
        func body() throws {
            let tmp = try TemporaryDirectory("pfx-tmptest")
            path = tmp.url.path
            throw Boom()
        }
        #expect(throws: Boom.self) { try body() }
        #expect(!path.isEmpty && !FileManager.default.fileExists(atPath: path))
    }
}
