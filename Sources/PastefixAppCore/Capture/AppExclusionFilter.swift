import AppKit

/// Rejects changes whose source app — or any app frontmost within the poll window — is on the
/// user's exclusion list. Runs at stage 1 so an excluded app's bytes are never read.
public struct AppExclusionFilter: CaptureFilter {
    private let excluded: Set<String>
    public init(excludedBundleIDs: [String]) { excluded = Set(excludedBundleIDs.map { $0.lowercased() }) }
    public func isExcluded(_ bundleID: String?) -> Bool { bundleID.map { excluded.contains($0.lowercased()) } ?? false }
    private func rejects(_ context: CaptureContext) -> Bool {
        isExcluded(context.sourceBundleID) || context.recentBundleIDs.contains(where: isExcluded)
    }
    public func shouldRead(types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool { !rejects(context) }
    public func shouldCapture(_ candidate: CaptureCandidate, types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool { !rejects(context) }
}
