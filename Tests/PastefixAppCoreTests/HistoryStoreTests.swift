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
            // Promote "a" with a different source (simulating AppModel.copyBack re-writing the
            // pasteboard, which the monitor then attributes to Pastefix itself) — the original
            // source must survive the promotion, only capturedAt refreshes.
            let again = s.record(text("a", app: "Pastefix"), now: Date(timeIntervalSince1970: 2_000_000_000))!
            #expect(again.id == a.id && s.items.count == 2 && s.items[0].id == a.id)
            #expect(s.items[0].capturedAt == Date(timeIntervalSince1970: 2_000_000_000))
            #expect(s.items[0].sourceAppName == "Notes")
            // Re-recording the top item is a no-op: a distinct `now:` must not be applied.
            let top = s.record(text("a"), now: Date(timeIntervalSince1970: 2_100_000_000))
            #expect(top?.id == a.id && s.items.count == 2)
            #expect(top?.capturedAt == Date(timeIntervalSince1970: 2_000_000_000))
            #expect(s.items[0].capturedAt == Date(timeIntervalSince1970: 2_000_000_000))
            #expect(s.items[0].sourceAppName == "Notes")
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
    @Test func itemCapNeverEvictsTheItemJustRecorded() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 0))
            let only = s.record(text("keep me"))
            #expect(only != nil)
            #expect(s.items.map(\.id) == [only?.id].compactMap { $0 })
        }
    }
    @Test func totalByteBudgetEvictsOldest() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 100, maxImageBytes: 100, maxTotalBytes: 150))
            let i1 = s.record(CaptureCandidate(imagePNG: png(1, size: 60)))!
            let i2 = s.record(CaptureCandidate(imagePNG: png(2, size: 60)))!
            let i3 = s.record(CaptureCandidate(imagePNG: png(3, size: 60)))!
            #expect(s.items.map(\.id) == [i3.id, i2.id])                   // the two newest survived
            #expect(s.totalBytes <= 150 && s.items.allSatisfy { $0.imageHash != nil })
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(i1.imageFile!).path))
        }
    }
    @Test func removeAndClear() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let i = s.record(CaptureCandidate(plainText: "x", richRTFD: Data([9])))!; s.record(text("y"))
            s.remove(i.id)
            #expect(s.items.count == 1 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(i.richRTFDFile!).path))
            // Durable without an explicit flush: a crash here must not resurrect the item.
            let afterRemove = try String(contentsOf: dir.appendingPathComponent("index.json"), encoding: .utf8)
            #expect(!afterRemove.contains("\"x\"") && afterRemove.contains("\"y\""))
            s.clear(); s.flush()
            #expect(s.items.isEmpty)
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(left == ["index.json"])
            let afterClear = try String(contentsOf: dir.appendingPathComponent("index.json"), encoding: .utf8)
            #expect(!afterClear.contains("\"y\""))
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
        let index = dir.appendingPathComponent("index.json")
        s.record(text("one"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: index.path))   // still inside the 250 ms debounce
        try await Task.sleep(for: .milliseconds(600))
        #expect(FileManager.default.fileExists(atPath: index.path))
        s.flush()   // no live pendingWrite when the temp dir goes away
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
    /// A quarantined index holds the plaintext of every item it described, so only the most
    /// recent one is ever kept: a second corrupt index replaces the first rather than adding to it.
    @Test func quarantineKeepsOnlyTheNewestCorruptIndex() throws {
        try withDir { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for payload in ["first garbage", "second garbage"] {
                try Data(payload.utf8).write(to: dir.appendingPathComponent("index.json"))
                HistoryStore(directory: dir).flush()
            }
            let corrupt = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix("index.json.corrupt-") }
            #expect(corrupt.count == 1)
            let kept = try Data(contentsOf: dir.appendingPathComponent(corrupt[0]))
            #expect(String(decoding: kept, as: UTF8.self) == "second garbage")
        }
    }
    /// "Clear History" promises to remove every remembered item from disk; a quarantined index
    /// is a full plaintext copy of the history, so it has to go too.
    @Test func clearRemovesQuarantinedIndexes() throws {
        try withDir { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: dir.appendingPathComponent("index.json"))
            let s = HistoryStore(directory: dir)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("index.json.corrupt-") })
            s.record(text("after recovery"))
            s.clear()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!names.contains { $0.hasPrefix("index.json.corrupt-") })
            #expect(s.items.isEmpty)
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
    @Test func byteCountIsRecomputedFromDiskAtLoad() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let rich = s.record(CaptureCandidate(plainText: "keep", richRTFD: Data(count: 10_000)))!
            s.flush()
            #expect(rich.byteCount == 10_004)
            try FileManager.default.removeItem(at: dir.appendingPathComponent(rich.richRTFDFile!))
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items.count == 1 && s2.items[0].byteCount == 4 && s2.totalBytes == 4)
        }
    }
    @Test func orphanedBlobsAreSweptAtLoad() throws {
        try withDir { dir in
            let keeper: HistoryItem = {
                let s = HistoryStore(directory: dir)
                let img = s.record(CaptureCandidate(imagePNG: png(5)))!
                s.flush()
                return img
            }()
            let strayPNG = dir.appendingPathComponent("deadbeef.png")
            let strayRTFD = dir.appendingPathComponent("deadbeef.rtfd")
            try Data([0]).write(to: strayPNG); try Data([0]).write(to: strayRTFD)
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items.count == 1)
            #expect(!FileManager.default.fileExists(atPath: strayPNG.path))
            #expect(!FileManager.default.fileExists(atPath: strayRTFD.path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(keeper.imageFile!).path))
            #expect(s2.imagePNG(for: s2.items[0]) == png(5))
        }
    }
    @Test func traversingBlobNamesAreRejected() throws {
        try withDir { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let outside = dir.deletingLastPathComponent().appendingPathComponent("pfx-outside-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("top secret".utf8).write(to: outside)
            let escape = "../\(outside.lastPathComponent)"
            let id = UUID()
            let index = """
            [{"byteCount":10,"capturedAt":"2026-01-01T00:00:00Z","id":"\(id.uuidString)",\
            "imageFile":"\(escape)","imageHash":"deadbeef","richRTFDFile":"\(escape)"}]
            """
            try Data(index.utf8).write(to: dir.appendingPathComponent("index.json"))

            let s = HistoryStore(directory: dir)
            #expect(s.items.isEmpty)   // image-only item whose blob name isn't "<id>.png" → dropped
            let synthetic = HistoryItem(id: id, richRTFDFile: escape, imageFile: escape, byteCount: 10)
            #expect(s.imagePNG(for: synthetic) == nil)
            #expect(s.richRTFD(for: synthetic) == nil)
            s.clear()
            #expect(FileManager.default.fileExists(atPath: outside.path))
            #expect(try String(contentsOf: outside, encoding: .utf8) == "top secret")
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
    @Test func loweringLimitsIsDurableWithoutFlush() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            for i in 0..<5 { s.record(text("t\(i)")) }
            s.limits.maxItems = 3
            // No flush() here: a crash right now must not resurrect the shed items.
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items.map(\.plainText) == ["t4", "t3", "t2"])
        }
    }
    @Test func quarantineKeepsBlobsForRecovery() throws {
        try withDir { dir in
            let img: HistoryItem = {
                let s = HistoryStore(directory: dir)
                let i = s.record(CaptureCandidate(imagePNG: png(6)))!
                s.flush()
                return i
            }()
            try Data("not json".utf8).write(to: dir.appendingPathComponent("index.json"))
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items.isEmpty)
            // The sweep must not delete the payloads the quarantined index referenced.
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(img.imageFile!).path))
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names.contains { $0.hasPrefix("index.json.corrupt-") })
        }
    }
    @Test func quarantinedLoadIsFlaggedAndANormalOneIsNot() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            s.record(text("keep")); s.flush()
            #expect(!s.lastLoadQuarantined)                              // fresh directory
            #expect(!HistoryStore(directory: dir).lastLoadQuarantined)   // readable index
            try Data("not json".utf8).write(to: dir.appendingPathComponent("index.json"))
            // The flag distinguishes "no items" from "cannot read the items": callers key state
            // to item ids and must not discard it on the second one.
            let corrupt = HistoryStore(directory: dir)
            #expect(corrupt.items.isEmpty && corrupt.lastLoadQuarantined)
            // It describes the load, so the *next* launch (index rewritten) is clean again.
            corrupt.flush()
            #expect(!HistoryStore(directory: dir).lastLoadQuarantined)
        }
    }
    // MARK: Pinned snippets

    @Test func pinUnpinRenameAndOrdering() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let a = s.record(text("a"))!; let b = s.record(text("b"))!; s.record(text("c"))
            // Explicit `now:` on both pins: `sorted(by:)` is not stable, so two pins made in the
            // same instant could order either way and the assertion below would flake.
            s.pin(a.id, title: "  Alpha ", now: Date(timeIntervalSince1970: 1_000))
            s.pin(b.id, now: Date(timeIntervalSince1970: 2_000))
            #expect(s.pinnedItems.map(\.id) == [b.id, a.id])            // newest pinned first
            #expect(s.pinnedItems.last?.title == "Alpha")
            s.rename(b.id, title: "  "); #expect(s.pinnedItems.first?.title == nil)
            s.unpin(a.id)
            #expect(s.pinnedItems.map(\.id) == [b.id] && s.unpinnedItems.count == 2)
            #expect(s.items.first { $0.id == a.id }?.pinnedAt == nil)
            // Unpin keeps the user's label: a mis-hit ⌘P must be undoable, and a re-pin restores
            // the title rather than making the user type it again.
            #expect(s.items.first { $0.id == a.id }?.title == "Alpha")
        }
    }
    @Test func pinTextCreatesOrPromotes() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let existing = s.record(text("boiler"))!
            let promoted = s.pinText("boiler", richRTFD: nil, title: "B")!
            #expect(promoted.id == existing.id && promoted.pinned && promoted.title == "B")
            let fresh = s.pinText("new snippet", richRTFD: Data([1]), title: nil)!
            #expect(fresh.pinned && fresh.kind == .richText && fresh.sourceAppName == nil)
            #expect(s.pinText(String(repeating: "x", count: 300_000), richRTFD: nil, title: nil) == nil)
        }
    }
    @Test func copyingAPinIsANoOp() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let p = s.record(text("pin me"))!; s.pin(p.id); s.record(text("later"))
            let before = s.items.map(\.id)
            let r = s.record(text("pin me"), now: Date(timeIntervalSince1970: 2_000_000_000))
            #expect(r?.id == p.id && s.items.map(\.id) == before && s.items.first { $0.id == p.id }?.capturedAt == p.capturedAt)
        }
    }
    @Test func pinsAreExemptFromCapAndByteEviction() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 2, maxImageBytes: 100, maxTotalBytes: 150))
            let p = s.record(text("keep"))!; s.pin(p.id)
            s.record(text("1")); s.record(text("2")); s.record(text("3"))
            #expect(s.items.contains { $0.id == p.id } && s.unpinnedItems.count == 2)
            let img = s.record(CaptureCandidate(imagePNG: png(1, size: 90)))!; s.pin(img.id)
            s.record(CaptureCandidate(imagePNG: png(2, size: 90))); s.record(CaptureCandidate(imagePNG: png(3, size: 90)))
            #expect(s.items.contains { $0.id == img.id })
        }
    }
    @Test func clearKeepsPinsAndTheirBlobs() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let p = s.pinText("rich pin", richRTFD: Data([7]), title: nil)!; s.record(text("gone"))
            s.clear()
            #expect(s.items.map(\.id) == [p.id] && s.richRTFD(for: p) == Data([7]))
        }
    }
    @Test func unpinReappliesCap() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 1))
            let p = s.record(text("p"))!; s.pin(p.id); s.record(text("q"))
            s.unpin(p.id)
            // The cap is enforced again (2 unpinned -> 1), and the survivor is the item that
            // just rejoined: unpinning must never be a disguised delete.
            #expect(s.items.count == 1 && s.items[0].plainText == "p")
        }
    }
    @Test func unpinnedItemBecomesNewestNotTheNextVictim() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 5))
            let p = s.record(text("p"))!; s.pin(p.id)
            for i in 0..<5 { s.record(text("t\(i)")) }
            s.unpin(p.id)
            #expect(s.items.count == 5 && s.items[0].id == p.id)          // rejoins as the newest
            #expect(!s.items.contains { $0.plainText == "t0" })           // the oldest capture goes instead
            #expect(s.items[0].capturedAt > p.capturedAt)
        }
    }
    @Test func clearAllWipesPinsAndBlobsToo() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let p = s.pinText("rich pin", richRTFD: Data([7]), title: "T")!
            s.record(CaptureCandidate(imagePNG: png(3))); s.record(text("gone"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("index.json.corrupt-1"))
            s.clearAll()
            #expect(s.items.isEmpty && s.richRTFD(for: p) == nil)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names == ["index.json"])
        }
    }
    @Test func containsSecretFlagSetAtCaptureAndDecodesLegacyNil() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let a = s.record(text("token=9f8e7d6c5b4a39281706f5e4d3c2b1a0"))!; let b = s.record(text("hello"))!
            let img = s.record(CaptureCandidate(imagePNG: png(1)))!
            // Three states, not two: scanned and dirty, scanned and clean, never examined.
            #expect(a.containsSecret == true && b.containsSecret == false && img.containsSecret == nil)
            let p = s.pinText("AKIAIOSFODNN7EXAMPLE", richRTFD: nil, title: nil)!
            #expect(p.containsSecret == true)
            s.flush()
            #expect(HistoryStore(directory: dir).items.first { $0.id == a.id }?.containsSecret == true)
            let legacy = #"[{"id":"00000000-0000-0000-0000-000000000002","capturedAt":"2026-09-01T00:00:00Z","plainText":"AKIAIOSFODNN7EXAMPLE","byteCount":20}]"#
            try Data(legacy.utf8).write(to: dir.appendingPathComponent("index.json"))
            // Still not recomputed at load — but the row is now "unknown", so the overlay shows
            // no glyph without claiming the item is clean.
            #expect(HistoryStore(directory: dir).items[0].containsSecret == nil)
        }
    }
    @Test func recopyingRefreshesTheSecretFlagOnAnExistingItem() throws {
        try withDir { dir in
            // Two pre-Plan-11 rows (no `containsSecret` key), one of them pinned: both take the
            // identical-text early return in `record`, which used to leave the flag untouched, so
            // a legacy item never gained its shield however often the secret was copied again.
            let secret = "token=9f8e7d6c5b4a39281706f5e4d3c2b1a0"
            let legacy = """
            [{"id":"00000000-0000-0000-0000-000000000001","capturedAt":"2026-09-01T00:00:00Z","plainText":"\(secret)","byteCount":37},
             {"id":"00000000-0000-0000-0000-000000000002","capturedAt":"2026-09-01T00:00:00Z","plainText":"AKIAIOSFODNN7EXAMPLE","byteCount":20,"pinned":true,"pinnedAt":"2026-09-01T00:00:00Z"}]
            """
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(legacy.utf8).write(to: dir.appendingPathComponent("index.json"))
            let s = HistoryStore(directory: dir)
            #expect(s.items.count == 2 && s.items.allSatisfy { $0.containsSecret == nil })
            #expect(s.record(text(secret))?.containsSecret == true)
            #expect(s.record(text("AKIAIOSFODNN7EXAMPLE"))?.containsSecret == true)      // the pin
            #expect(s.items.allSatisfy { $0.containsSecret == true })
            s.flush()
            #expect(HistoryStore(directory: dir).items.allSatisfy { $0.containsSecret == true })
            // The refresh is a scan, not a latch: re-copying text with nothing in it records
            // false, twice, rather than leaving the row unknown or sticking on true.
            #expect(s.record(text("hello"))?.containsSecret == false)
            #expect(s.record(text("hello"))?.containsSecret == false)
        }
    }
    @Test func pinFieldsPersistAndOldIndexesLoad() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let p = s.record(text("x"))!; s.pin(p.id, title: "T"); s.flush()
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items[0].pinned && s2.items[0].title == "T" && s2.items[0].pinnedAt != nil)
            // Pre-Plan-9 index: no pinned/pinnedAt/title keys.
            let legacy = #"[{"id":"00000000-0000-0000-0000-000000000001","capturedAt":"2026-09-01T00:00:00Z","plainText":"old","byteCount":3}]"#
            try Data(legacy.utf8).write(to: dir.appendingPathComponent("index.json"))
            let s3 = HistoryStore(directory: dir)
            #expect(s3.items.count == 1 && s3.items[0].pinned == false && s3.items[0].title == nil)
        }
    }
}
