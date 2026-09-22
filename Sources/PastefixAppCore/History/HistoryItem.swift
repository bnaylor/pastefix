import Foundation

/// One remembered clipboard item. Text is inline; rich/image payloads live in blob files
/// next to the index, named by this item's id.
public struct HistoryItem: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, richText, image }

    public let id: UUID
    public var capturedAt: Date
    public var plainText: String?
    public var richRTFDFile: String?
    public var imageFile: String?
    public var imagePixelWidth: Int?
    public var imagePixelHeight: Int?
    public var imageHash: String?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var byteCount: Int
    /// Pinned items are exempt from eviction and from `clear()`; see `HistoryStore`.
    public var pinned: Bool
    /// When the item was pinned. Orders the pinned section (newest pin first); nil when unpinned.
    public var pinnedAt: Date?
    /// Optional user-supplied label, shown instead of the preview and searched alongside the body.
    public var title: String?
    /// Whether `SecretDetector` found a match in `plainText` at capture (or pin-time promotion).
    /// Never recomputed at load: `load()` stays pure, so an index written before Plan 11 decodes
    /// to `false` rather than re-scanning every item's text on every launch.
    public var containsSecret: Bool = false

    public init(id: UUID = UUID(), capturedAt: Date = Date(), plainText: String? = nil,
                richRTFDFile: String? = nil, imageFile: String? = nil,
                imagePixelWidth: Int? = nil, imagePixelHeight: Int? = nil, imageHash: String? = nil,
                sourceBundleID: String? = nil, sourceAppName: String? = nil, byteCount: Int = 0,
                pinned: Bool = false, pinnedAt: Date? = nil, title: String? = nil, containsSecret: Bool = false) {
        self.id = id; self.capturedAt = capturedAt; self.plainText = plainText
        self.richRTFDFile = richRTFDFile; self.imageFile = imageFile
        self.imagePixelWidth = imagePixelWidth; self.imagePixelHeight = imagePixelHeight; self.imageHash = imageHash
        self.sourceBundleID = sourceBundleID; self.sourceAppName = sourceAppName; self.byteCount = byteCount
        self.pinned = pinned; self.pinnedAt = pinnedAt; self.title = title; self.containsSecret = containsSecret
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, plainText, richRTFDFile, imageFile, imagePixelWidth, imagePixelHeight
        case imageHash, sourceBundleID, sourceAppName, byteCount, pinned, pinnedAt, title, containsSecret
    }

    /// Hand-written so an index written before pinning existed still loads: every key added
    /// after v1 is optional here. The encoder stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        plainText = try c.decodeIfPresent(String.self, forKey: .plainText)
        richRTFDFile = try c.decodeIfPresent(String.self, forKey: .richRTFDFile)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imagePixelWidth = try c.decodeIfPresent(Int.self, forKey: .imagePixelWidth)
        imagePixelHeight = try c.decodeIfPresent(Int.self, forKey: .imagePixelHeight)
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        containsSecret = try c.decodeIfPresent(Bool.self, forKey: .containsSecret) ?? false
    }

    public var kind: Kind {
        if imageFile != nil { return .image }
        return richRTFDFile != nil ? .richText : .text
    }
    public var hasText: Bool { !(plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
