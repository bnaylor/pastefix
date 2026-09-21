import Foundation
import CryptoKit
import os

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
@MainActor
public final class HistoryStore: ObservableObject {
    @Published public private(set) var items: [HistoryItem] = []
    public var limits: HistoryLimits { didSet { enforceLimits(); scheduleWrite() } }
    public let directory: URL
    public private(set) var lastWriteError: String?

    private let indexURL: URL
    private var pendingWrite: Task<Void, Never>?
    private static let log = Logger(subsystem: "net.scromp.Pastefix", category: "history")
    private static let writeDelay: Duration = .milliseconds(250)

    public init(directory: URL, limits: HistoryLimits = .init()) {
        self.directory = directory
        self.limits = limits
        self.indexURL = directory.appendingPathComponent("index.json")
        Self.ensureDirectory(directory)
        load()
        enforceLimits()
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
            if existing == 0 { return items[0] }
            var moved = items.remove(at: existing)
            moved.capturedAt = now
            moved.sourceBundleID = candidate.sourceBundleID
            moved.sourceAppName = candidate.sourceAppName
            items.insert(moved, at: 0)
            scheduleWrite()
            return moved
        }

        let id = UUID()
        var item = HistoryItem(id: id, capturedAt: now, plainText: text,
                               imagePixelWidth: candidate.imagePixelWidth, imagePixelHeight: candidate.imagePixelHeight,
                               imageHash: hash, sourceBundleID: candidate.sourceBundleID, sourceAppName: candidate.sourceAppName)
        var bytes = text?.utf8.count ?? 0
        if let rich, writeBlob(rich, name: "\(id.uuidString).rtfd") { item.richRTFDFile = "\(id.uuidString).rtfd"; bytes += rich.count }
        if let image, writeBlob(image, name: "\(id.uuidString).png") { item.imageFile = "\(id.uuidString).png"; bytes += image.count }
        guard item.hasText || item.imageFile != nil else { return nil }
        item.byteCount = bytes
        items.insert(item, at: 0)
        enforceLimits()
        scheduleWrite()
        return item
    }

    public func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        deleteBlobs(of: items.remove(at: i))
        scheduleWrite()
    }

    public func clear() {
        items.forEach(deleteBlobs)
        items.removeAll()
        scheduleWrite()
    }

    public func richRTFD(for item: HistoryItem) -> Data? { item.richRTFDFile.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) } }
    public func imagePNG(for item: HistoryItem) -> Data? { item.imageFile.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) } }
    public var totalBytes: Int { items.reduce(0) { $0 + $1.byteCount } }

    // MARK: Limits

    private func enforceLimits() {
        while items.count > limits.maxItems, let last = items.popLast() { deleteBlobs(of: last) }
        while totalBytes > limits.maxTotalBytes, items.count > 1, let last = items.popLast() { deleteBlobs(of: last) }
    }

    // MARK: Files

    private static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeBlob(_ data: Data, name: String) -> Bool {
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            lastWriteError = error.localizedDescription
            Self.log.error("blob write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func deleteBlobs(of item: HistoryItem) {
        for name in [item.richRTFDFile, item.imageFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Index persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var loaded = try? decoder.decode([HistoryItem].self, from: data) else {
            let quarantine = directory.appendingPathComponent("index.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: indexURL, to: quarantine)
            Self.log.error("history index unreadable; moved aside")
            return
        }
        let fm = FileManager.default
        loaded = loaded.compactMap { item in
            var it = item
            if let f = it.richRTFDFile, !fm.fileExists(atPath: directory.appendingPathComponent(f).path) { it.richRTFDFile = nil }
            if let f = it.imageFile, !fm.fileExists(atPath: directory.appendingPathComponent(f).path) {
                it.imageFile = nil; it.imageHash = nil; it.imagePixelWidth = nil; it.imagePixelHeight = nil
            }
            return (it.hasText || it.imageFile != nil) ? it : nil
        }
        items = loaded
    }

    private func encodedIndex() -> Data? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(items)
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            self?.writeIndexNow()
        }
    }

    /// Writes the index synchronously. Tests and `applicationWillTerminate` call this.
    public func flush() {
        pendingWrite?.cancel(); pendingWrite = nil
        writeIndexNow()
    }

    private func writeIndexNow() {
        guard let data = encodedIndex() else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            Self.log.error("history index write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
