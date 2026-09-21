import Testing
import Foundation
@testable import PastefixAppCore

@MainActor
@Suite struct HistoryStoreTests {
    private func withDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pfx-hist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
    private func text(_ s: String, app: String? = "Notes") -> CaptureCandidate { CaptureCandidate(plainText: s, sourceAppName: app) }
    private func png(_ byte: UInt8, size: Int = 64) -> Data { Data(repeating: byte, count: size) }   // the store treats PNG as opaque bytes
    private func perms(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }

    @Test func recordsNewestFirstWithKindAndSource() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            s.record(text("one")); s.record(text("two"))
            #expect(s.items.map(\.plainText) == ["two", "one"])
            #expect(s.items[0].kind == .text && s.items[0].sourceAppName == "Notes")
        }
    }
    @Test func richAndImageWriteBlobs() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let rich = s.record(CaptureCandidate(plainText: "hi", richRTFD: Data([1, 2, 3])))!
            let img = s.record(CaptureCandidate(imagePNG: png(7), imagePixelWidth: 10, imagePixelHeight: 5))!
            #expect(rich.kind == .richText && s.richRTFD(for: rich) == Data([1, 2, 3]))
            #expect(img.kind == .image && s.imagePNG(for: img) == png(7) && img.imagePixelWidth == 10)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(rich.richRTFDFile!).path))
            #expect(perms(dir.appendingPathComponent(img.imageFile!)) == 0o600)
            #expect(perms(dir) & 0o777 == 0o700)
        }
    }
    @Test func budgetsDropRepresentations() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 10, maxTextBytes: 8, maxRichBytes: 4, maxImageBytes: 4, maxTotalBytes: 1_000))
            #expect(s.record(text("123456789")) == nil)                                   // text too big → dropped
            let r = s.record(CaptureCandidate(plainText: "ok", richRTFD: Data(count: 5)))! // rich too big → text kept
            #expect(r.kind == .text && r.richRTFDFile == nil)
            #expect(s.record(CaptureCandidate(imagePNG: Data(count: 5))) == nil)           // image too big, no text → nil
        }
    }
    @Test func whitespaceOnlyIgnored() throws {
        try withDir { dir in let s = HistoryStore(directory: dir); #expect(s.record(text(" \n\t")) == nil); #expect(s.items.isEmpty) }
    }
    @Test func duplicateAtTopIsNoOpAndLowerDuplicateMovesUp() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let a = s.record(text("a"))!; s.record(text("b"))
            let again = s.record(text("a"), now: Date(timeIntervalSince1970: 2_000_000_000))!
            #expect(again.id == a.id && s.items.count == 2 && s.items[0].id == a.id)
            #expect(s.items[0].capturedAt == Date(timeIntervalSince1970: 2_000_000_000))
            let top = s.record(text("a"))
            #expect(top?.id == a.id && s.items.count == 2)
        }
    }
    @Test func imageDeduplicatesByHash() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let i1 = s.record(CaptureCandidate(imagePNG: png(1)))!; s.record(CaptureCandidate(imagePNG: png(2)))
            let i3 = s.record(CaptureCandidate(imagePNG: png(1)))!
            #expect(i3.id == i1.id && s.items.count == 2 && s.items[0].id == i1.id)
            try #expect(FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.count == 2)
        }
    }
    @Test func itemCapEvictsOldestAndDeletesBlobs() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 2))
            let old = s.record(CaptureCandidate(imagePNG: png(1)))!
            s.record(text("b")); s.record(text("c"))
            #expect(s.items.count == 2 && !s.items.contains { $0.id == old.id })
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(old.imageFile!).path))
        }
    }
    @Test func totalByteBudgetEvictsOldest() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 100, maxImageBytes: 100, maxTotalBytes: 150))
            s.record(CaptureCandidate(imagePNG: png(1, size: 60))); s.record(CaptureCandidate(imagePNG: png(2, size: 60)))
            s.record(CaptureCandidate(imagePNG: png(3, size: 60)))
            #expect(s.items.count == 2 && s.totalBytes <= 150 && s.items.allSatisfy { $0.imageHash != nil })
        }
    }
    @Test func removeAndClear() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let i = s.record(CaptureCandidate(plainText: "x", richRTFD: Data([9])))!; s.record(text("y"))
            s.remove(i.id)
            #expect(s.items.count == 1 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(i.richRTFDFile!).path))
            s.clear(); s.flush()
            #expect(s.items.isEmpty)
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(left == ["index.json"])
        }
    }
    @Test func persistsAcrossInstances() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            s.record(text("one")); s.record(CaptureCandidate(plainText: "two", richRTFD: Data([4])))
            s.flush()
            #expect(perms(dir.appendingPathComponent("index.json")) == 0o600)
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items.map(\.plainText) == ["two", "one"])
            #expect(s2.richRTFD(for: s2.items[0]) == Data([4]))
        }
    }
    @Test func debouncedWriteLandsWithoutFlush() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pfx-hist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = HistoryStore(directory: dir)
        s.record(text("one"))
        try await Task.sleep(for: .milliseconds(600))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json").path))
    }
    @Test func corruptIndexIsQuarantined() throws {
        try withDir { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: dir.appendingPathComponent("index.json"))
            let s = HistoryStore(directory: dir)
            #expect(s.items.isEmpty)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names.contains { $0.hasPrefix("index.json.corrupt-") })
        }
    }
    @Test func missingBlobDegradesOrDrops() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let rich = s.record(CaptureCandidate(plainText: "keep", richRTFD: Data([1])))!
            let img = s.record(CaptureCandidate(imagePNG: png(3)))!
            s.flush()
            try FileManager.default.removeItem(at: dir.appendingPathComponent(rich.richRTFDFile!))
            try FileManager.default.removeItem(at: dir.appendingPathComponent(img.imageFile!))
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items.count == 1 && s2.items[0].plainText == "keep" && s2.items[0].kind == .text)
        }
    }
    @Test func loweringLimitsTrimsImmediately() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            for i in 0..<5 { s.record(text("t\(i)")) }
            s.limits.maxItems = 3
            #expect(s.items.count == 3 && s.items[0].plainText == "t4")
        }
    }
}
