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

    public init(id: UUID = UUID(), capturedAt: Date = Date(), plainText: String? = nil,
                richRTFDFile: String? = nil, imageFile: String? = nil,
                imagePixelWidth: Int? = nil, imagePixelHeight: Int? = nil, imageHash: String? = nil,
                sourceBundleID: String? = nil, sourceAppName: String? = nil, byteCount: Int = 0) {
        self.id = id; self.capturedAt = capturedAt; self.plainText = plainText
        self.richRTFDFile = richRTFDFile; self.imageFile = imageFile
        self.imagePixelWidth = imagePixelWidth; self.imagePixelHeight = imagePixelHeight; self.imageHash = imageHash
        self.sourceBundleID = sourceBundleID; self.sourceAppName = sourceAppName; self.byteCount = byteCount
    }

    public var kind: Kind {
        if imageFile != nil { return .image }
        return richRTFDFile != nil ? .richText : .text
    }
    public var hasText: Bool { !(plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
