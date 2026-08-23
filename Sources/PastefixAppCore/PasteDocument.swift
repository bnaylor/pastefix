import Foundation

/// The editing session for one summon: the origin clipboard snapshot plus a
/// linear history of working-text states with an undo/redo cursor.
public struct PasteDocument: Sendable {
    public let origin: ClipboardSnapshot
    public private(set) var history: [String]
    public private(set) var cursor: Int

    public init(origin: ClipboardSnapshot) {
        self.origin = origin
        self.history = [origin.plainText ?? ""]
        self.cursor = 0
    }

    public var working: String { history[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count - 1 }

    /// Append a new state (e.g. a transform result). No-op if unchanged.
    public mutating func pushState(_ text: String) {
        guard text != working else { return }
        history = Array(history.prefix(cursor + 1))
        history.append(text)
        cursor = history.count - 1
    }

    /// Coalesce a manual edit into the current state (no new history entry).
    public mutating func setWorking(_ text: String) {
        history[cursor] = text
    }

    public mutating func undo() { if canUndo { cursor -= 1 } }
    public mutating func redo() { if canRedo { cursor += 1 } }

    public mutating func refresh(origin: ClipboardSnapshot) {
        self = PasteDocument(origin: origin)
    }
}
