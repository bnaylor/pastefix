import Foundation
import CryptoKit
import os
import PastefixCore

/// File-scope so the off-main index writer can log without touching main-actor state.
private let historyLog = Logger(subsystem: "net.scromp.Pastefix", category: "history")

public struct HistoryLimits: Sendable, Equatable {
    public var maxItems: Int
    public var maxTextBytes: Int
    public var maxRichBytes: Int
    public var maxImageBytes: Int
    public var maxTotalBytes: Int
    public init(maxItems: Int = 200, maxTextBytes: Int = 262_144, maxRichBytes: Int = 1_048_576,
                maxImageBytes: Int = 5_242_880, maxTotalBytes: Int = 52_428_800) {
        self.maxItems = maxItems; self.maxTextBytes = maxTextBytes; self.maxRichBytes = maxRichBytes
        self.maxImageBytes = maxImageBytes; self.maxTotalBytes = maxTotalBytes
    }
}

/// What the pasteboard offered for one change, before budgets and filters.
public struct CaptureCandidate: Sendable {
    public var plainText: String?
    public var richRTFD: Data?
    public var imagePNG: Data?
    public var imagePixelWidth: Int?
    public var imagePixelHeight: Int?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public init(plainText: String? = nil, richRTFD: Data? = nil, imagePNG: Data? = nil,
                imagePixelWidth: Int? = nil, imagePixelHeight: Int? = nil,
                sourceBundleID: String? = nil, sourceAppName: String? = nil) {
        self.plainText = plainText; self.richRTFD = richRTFD; self.imagePNG = imagePNG
        self.imagePixelWidth = imagePixelWidth; self.imagePixelHeight = imagePixelHeight
        self.sourceBundleID = sourceBundleID; self.sourceAppName = sourceAppName
    }
}

/// Persisted, capped clipboard history. Index in `index.json`; rich/image payloads as
/// per-item blob files. Owner-only permissions; atomic writes; debounced index writes.
///
/// Blob paths are never taken from the index: every read, write and delete derives the
/// file name from the item's `id`, so a hand-edited or restored index cannot point the
/// store at a file outside `directory`.
@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var items: [HistoryItem] = []
    /// Lowering a limit sheds items and deletes their blobs immediately, so that trim is
    /// flushed rather than debounced: a crash inside the debounce window would otherwise
    /// bring the shed items back as text-only entries on the next launch.
    public var limits: HistoryLimits { didSet { if enforceLimits() { flush() } else { scheduleWrite() } } }
    public let directory: URL

    /// True when this launch found `index.json` unreadable and moved it aside.
    ///
    /// Set once, in `init`, and never cleared: it describes the load, not the current contents.
    /// Callers use it to tell "the user has no pins" from "we cannot see the user's pins" —
    /// `items` is empty either way, but only one of those justifies discarding state keyed to
    /// item ids (see `SnippetHotkeys`).
    public private(set) var lastLoadQuarantined = false

    /// Last index-write failure, or nil after a success.
    ///
    /// Eventually consistent: index writes run off the main actor, so this is updated on a
    /// later main-actor turn than the mutation that triggered the write. Do not read it
    /// synchronously after `record`/`flush` and expect the outcome of that write.
    @Published public private(set) var lastWriteError: String?

    private let indexURL: URL
    private var pendingWrite: Task<Void, Never>?
    /// Serial, so an older snapshot can never land on top of a newer one.
    private let writeQueue = DispatchQueue(label: "net.scromp.Pastefix.history.index", qos: .utility)
    private static let writeDelay: Duration = .milliseconds(250)
    private static let richExtension = "rtfd"
    private static let imageExtension = "png"
    private static let quarantinePrefix = "index.json.corrupt-"

    public init(directory: URL, limits: HistoryLimits = .init()) {
        self.directory = directory
        self.limits = limits
        self.indexURL = directory.appendingPathComponent("index.json")
        Self.ensureDirectory(directory)
        let outcome = load()
        lastLoadQuarantined = outcome.quarantined
        let evicted = enforceLimits()
        // A quarantined index is the only remaining record of which blob belongs to which
        // item, so sweeping against an empty `items` would delete exactly the payloads the
        // quarantine exists to preserve. Skip the sweep on that launch only.
        if !outcome.quarantined { sweepOrphanBlobs() }
        // Load-time repair and trimming delete blobs immediately; the index has to follow
        // synchronously or a crash resurrects items whose payloads are already gone.
        if outcome.needsRewrite || evicted { flush() }
    }

    // MARK: Recording

    @discardableResult
    public func record(_ candidate: CaptureCandidate, now: Date = Date()) -> HistoryItem? {
        var text = candidate.plainText
        if let t = text, t.utf8.count > limits.maxTextBytes { return nil }
        if let t = text, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = nil }
        let rich = candidate.richRTFD.flatMap { $0.count <= limits.maxRichBytes ? $0 : nil }
        let image = candidate.imagePNG.flatMap { $0.count <= limits.maxImageBytes ? $0 : nil }
        guard text != nil || image != nil else { return nil }

        let hash = image.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        if let existing = items.firstIndex(where: { hash != nil ? $0.imageHash == hash : ($0.imageFile == nil && $0.plainText == text) }) {
            // A pin holds its own place: copying it again must not drag it into the recency
            // list or refresh `capturedAt`, which would reorder the unpinned section around it.
            if items[existing].pinned { return items[existing] }
            if existing == 0 { return items[0] }
            var moved = items.remove(at: existing)
            moved.capturedAt = now
            // Keep the ORIGINAL source: re-copying an item (e.g. AppModel.copyBack) re-writes
            // the pasteboard, which the monitor then records as coming from Pastefix itself —
            // relabeling every reused item would erase where it actually came from.
            items.insert(moved, at: 0)
            scheduleWrite()
            return moved
        }

        let id = UUID()
        var item = HistoryItem(id: id, capturedAt: now, plainText: text,
                               imagePixelWidth: candidate.imagePixelWidth, imagePixelHeight: candidate.imagePixelHeight,
                               imageHash: hash, sourceBundleID: candidate.sourceBundleID, sourceAppName: candidate.sourceAppName)
        var bytes = text?.utf8.count ?? 0
        if let rich, writeBlob(rich, id: id, ext: Self.richExtension) {
            item.richRTFDFile = Self.blobName(id, ext: Self.richExtension)
            bytes += rich.count
        }
        if let image, writeBlob(image, id: id, ext: Self.imageExtension) {
            item.imageFile = Self.blobName(id, ext: Self.imageExtension)
            bytes += image.count
        }
        // Text only: an image capture is never scanned, even if it also carries plain text.
        if item.imageFile == nil, let t = text {
            item.containsSecret = !SecretDetector.scan(t).isEmpty
        }
        guard item.hasText || item.imageFile != nil else {
            // The item is abandoned (e.g. the image write failed and there is no text left),
            // so anything already written for it would be an orphan.
            deleteBlobs(ofItemWith: id)
            return nil
        }
        item.byteCount = bytes
        items.insert(item, at: 0)
        enforceLimits()
        scheduleWrite()
        return item
    }

    public func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        deleteBlobs(ofItemWith: id)
        flush()   // user-initiated deletion: durable immediately, debounce buys nothing
    }

    /// Drops every unpinned item and its blobs. Pins survive: they are saved snippets, not
    /// history, and "clear history" is not "delete my snippets". Use `clearAll` to drop those too.
    public func clear() {
        let victims = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        victims.forEach { deleteBlobs(ofItemWith: $0.id) }
        // A quarantined index is a verbatim plaintext copy of the history it described, so
        // "removes every remembered item and its files from disk" has to cover it.
        removeQuarantinedIndexes()
        flush()
    }

    /// The panic button: removes every item including pins, every blob, and every quarantined
    /// index. Nothing a user could call "remembered" is left in `directory` but `index.json`.
    public func clearAll() {
        let ids = items.map(\.id)
        items.removeAll()
        ids.forEach(deleteBlobs(ofItemWith:))
        removeQuarantinedIndexes()
        flush()
    }

    // MARK: Pinning

    /// Pinned items, newest pin first. Independent of `items` order, which stays recency.
    public var pinnedItems: [HistoryItem] {
        items.filter(\.pinned).sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }
    public var unpinnedItems: [HistoryItem] { items.filter { !$0.pinned } }

    /// Pin mutations flush like `remove`: a pin the user just made must survive a crash inside
    /// the debounce window, and an unpin can evict blobs that are already gone from disk.
    public func pin(_ id: UUID, title: String? = nil, now: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = true
        items[i].pinnedAt = now
        items[i].title = Self.cleanTitle(title) ?? items[i].title
        flush()
    }

    /// Unpinning rejoins the capped section as the NEWEST entry, not at the item's original
    /// capture position: a long-lived pin is the oldest thing in `items`, so re-applying the
    /// limits against its old `capturedAt` would evict the item the user just unpinned. It
    /// behaves like a fresh capture instead.
    ///
    /// The `title` is deliberately kept. Unpinning is one unconfirmed keystroke (⌘P toggles), and
    /// the title is text the user typed — clearing it would make a mis-hit destructive rather than
    /// reversible, and re-pinning the same item is far more likely to be an undo than a fresh
    /// start. Only the pin state itself is cleared; surfaces show the label for pinned rows only,
    /// so a retained title is invisible until the item is pinned again. `rename(_:title:)` with a
    /// blank string is how a user actually clears one.
    public func unpin(_ id: UUID, now: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: i)
        item.pinned = false
        item.pinnedAt = nil
        item.capturedAt = now
        items.insert(item, at: 0)
        // The item rejoins the capped section, which may now be over its limits.
        _ = enforceLimits()
        flush()
    }

    /// Sets or clears the label. A blank title clears it.
    public func rename(_ id: UUID, title: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = Self.cleanTitle(title)
        flush()
    }

    /// Pins `text`, promoting an existing identical text item rather than duplicating it.
    /// Returns nil when `record` refuses the text (over `maxTextBytes`, or empty).
    @discardableResult
    public func pinText(_ text: String, richRTFD: Data?, title: String?, now: Date = Date()) -> HistoryItem? {
        if let i = items.firstIndex(where: { $0.imageFile == nil && $0.plainText == text }) {
            items[i].containsSecret = !SecretDetector.scan(text).isEmpty
            pin(items[i].id, title: title, now: now)
            return items[i]
        }
        guard let created = record(CaptureCandidate(plainText: text, richRTFD: richRTFD), now: now) else { return nil }
        pin(created.id, title: title, now: now)
        return items.first { $0.id == created.id }
    }

    private static func cleanTitle(_ t: String?) -> String? {
        let s = t?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    public func richRTFD(for item: HistoryItem) -> Data? {
        guard item.richRTFDFile != nil else { return nil }
        return try? Data(contentsOf: blobURL(item.id, ext: Self.richExtension))
    }

    public func imagePNG(for item: HistoryItem) -> Data? {
        guard item.imageFile != nil else { return nil }
        return try? Data(contentsOf: blobURL(item.id, ext: Self.imageExtension))
    }

    public var totalBytes: Int { items.reduce(0) { $0 + $1.byteCount } }

    // MARK: Limits

    /// Returns true when anything was evicted.
    @discardableResult
    private func enforceLimits() -> Bool {
        var evicted = false
        // Pins are exempt from both budgets: the victim is always the oldest UNPINNED item,
        // and a history of nothing but pins never evicts anything.
        func evictOldestUnpinned() -> Bool {
            guard let i = items.lastIndex(where: { !$0.pinned }) else { return false }
            let victim = items.remove(at: i)
            deleteBlobs(ofItemWith: victim.id)
            return true
        }
        // Floor of 1: the cap must never evict the item `record` just inserted and is about
        // to return, even if a caller sets `maxItems` to zero or a negative number.
        let cap = max(1, limits.maxItems)
        while unpinnedItems.count > cap, evictOldestUnpinned() { evicted = true }
        // `unpinnedItems.count > 1` deliberately leaves a single unpinned item that is on its
        // own larger than maxTotalBytes in place, over budget, rather than evicting what was
        // just recorded. Unreachable with the shipped defaults (5 MB + 256 KB per item vs 50 MB
        // total) unless pins alone already exceed them.
        while totalBytes > limits.maxTotalBytes, unpinnedItems.count > 1, evictOldestUnpinned() { evicted = true }
        return evicted
    }

    // MARK: Files

    private static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func blobName(_ id: UUID, ext: String) -> String { "\(id.uuidString).\(ext)" }

    /// The only way a blob path is ever formed: from the item's id, never from the index.
    private func blobURL(_ id: UUID, ext: String) -> URL {
        directory.appendingPathComponent(Self.blobName(id, ext: ext))
    }

    private func writeBlob(_ data: Data, id: UUID, ext: String) -> Bool {
        let url = blobURL(id, ext: ext)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lastWriteError = error.localizedDescription
            historyLog.error("blob write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The bytes landed but not at 0600; drop the file rather than keep a
            // world-readable payload or leave an unreferenced orphan behind.
            try? FileManager.default.removeItem(at: url)
            lastWriteError = error.localizedDescription
            historyLog.error("blob chmod failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    private func deleteBlobs(ofItemWith id: UUID) {
        for ext in [Self.richExtension, Self.imageExtension] {
            try? FileManager.default.removeItem(at: blobURL(id, ext: ext))
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else { return 0 }
        return size
    }

    /// Deletes every blob file the surviving items do not reference: payloads left behind by a
    /// crash before the debounced index write, or by an index that was rolled back.
    private func sweepOrphanBlobs() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var referenced = Set<String>()
        for item in items {
            if let name = item.richRTFDFile { referenced.insert(name) }
            if let name = item.imageFile { referenced.insert(name) }
        }
        for name in names
        where (name.hasSuffix(".\(Self.richExtension)") || name.hasSuffix(".\(Self.imageExtension)"))
            && !referenced.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
            historyLog.debug("removed orphaned history blob")
        }
    }

    /// Deletes every `index.json.corrupt-*` left by a previous quarantine.
    private func removeQuarantinedIndexes() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.quarantinePrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Index persistence

    /// What `load()` found: whether the in-memory index now differs from the file (so it must
    /// be rewritten), and whether an unreadable index was moved aside.
    private struct LoadOutcome {
        var needsRewrite = false
        var quarantined = false
    }

    /// Loads `index.json`, dropping references that are missing or not the exact name this
    /// store would have written, and recomputing `byteCount` from what is actually on disk.
    private func load() -> LoadOutcome {
        guard let data = try? Data(contentsOf: indexURL) else { return LoadOutcome() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([HistoryItem].self, from: data) else {
            // At most one quarantine ever exists: each holds the plaintext of every item in the
            // history at the time it was written, and keeping a pile of them would mean a single
            // bad byte leaves plaintext on disk indefinitely. Dropping the older one first also
            // frees the name when two quarantines land in the same second.
            removeQuarantinedIndexes()
            let quarantine = directory.appendingPathComponent(Self.quarantinePrefix + "\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: indexURL, to: quarantine)
            historyLog.error("history index unreadable; moved aside")
            return LoadOutcome(quarantined: true)
        }
        let fm = FileManager.default
        var repaired = false
        items = loaded.compactMap { item in
            var it = item
            if let name = it.richRTFDFile {
                let url = blobURL(it.id, ext: Self.richExtension)
                if name != Self.blobName(it.id, ext: Self.richExtension) || !fm.fileExists(atPath: url.path) {
                    it.richRTFDFile = nil
                }
            }
            if let name = it.imageFile {
                let url = blobURL(it.id, ext: Self.imageExtension)
                if name != Self.blobName(it.id, ext: Self.imageExtension) || !fm.fileExists(atPath: url.path) {
                    it.imageFile = nil; it.imageHash = nil; it.imagePixelWidth = nil; it.imagePixelHeight = nil
                }
            }
            var bytes = it.plainText?.utf8.count ?? 0
            if it.richRTFDFile != nil { bytes += Self.fileSize(blobURL(it.id, ext: Self.richExtension)) }
            if it.imageFile != nil { bytes += Self.fileSize(blobURL(it.id, ext: Self.imageExtension)) }
            it.byteCount = bytes
            guard it.hasText || it.imageFile != nil else { repaired = true; return nil }
            if it != item { repaired = true }
            return it
        }
        return LoadOutcome(needsRewrite: repaired)
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            // Load-bearing: `try?` swallows the CancellationError from a cancelled sleep, so
            // without this guard a superseded debounce task would still write.
            guard !Task.isCancelled, let self else { return }
            self.enqueueIndexWrite()
        }
    }

    /// Writes the index synchronously. Tests, `remove`/`clear`, and `applicationWillTerminate`
    /// call this; it returns only once the write has completed on the writer queue.
    public func flush() {
        pendingWrite?.cancel(); pendingWrite = nil
        enqueueIndexWrite()
        writeQueue.sync {}
    }

    /// Hands a snapshot of `items` to the serial writer queue; encoding and I/O happen there.
    private func enqueueIndexWrite() {
        let snapshot = items
        let url = indexURL
        writeQueue.async { [weak self] in
            let failure = Self.writeIndex(snapshot, to: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.lastWriteError = failure }
            }
        }
    }

    private nonisolated static func writeIndex(_ items: [HistoryItem], to url: URL) -> String? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(items)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return nil
        } catch {
            historyLog.error("history index write failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }
}
