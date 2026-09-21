import AppKit

/// What the monitor knows about a pasteboard change before it reads any content.
public struct CaptureContext: Sendable, Equatable {
    /// Frontmost app when the change was noticed — the best attribution we have.
    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// Every app frontmost within the poll window, newest first, `sourceBundleID` included.
    /// Filters must treat all of them as possible sources (Critical Invariant 12).
    public var recentBundleIDs: [String]
    public init(sourceBundleID: String? = nil, sourceAppName: String? = nil, recentBundleIDs: [String] = []) {
        self.sourceBundleID = sourceBundleID; self.sourceAppName = sourceAppName; self.recentBundleIDs = recentBundleIDs
    }
}

/// Decides whether a pasteboard change may enter history, in two stages: `shouldRead` runs on
/// declared types and the pre-read context before any content is touched, so content is never
/// read when it won't be captured; `shouldCapture` runs after the read on the full candidate, the
/// union of pre- and post-read types, and a refreshed context. Filters run in order; any `false` wins.
public protocol CaptureFilter: Sendable {
    func shouldRead(types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool
    func shouldCapture(_ candidate: CaptureCandidate, types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool
}
