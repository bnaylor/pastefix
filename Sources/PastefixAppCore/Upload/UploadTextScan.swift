import Foundation
import PastefixCore

/// The upload overlay's secret scan, and the one lane every such scan runs through (#63).
///
/// The scan is uncapped (`scanIgnoringSizeCap`: a scan that refused a large buffer would report
/// "No secrets found" on text nobody looked at, immediately before sending it off the machine)
/// and uncancellable once started. Each overlay used to run its own in a detached task, so a
/// dismissed overlay's scan kept running and a second ⌘⇧U started another beside it: two
/// overlapping scans at the 16 MB admission cap were ~7 s of CPU and ~96 MB resident. Through
/// `SingleSlotLane` — the shape image preparation (#48) and history capture already use — at most
/// one scan runs and one waits, process-wide, and a newer overlay's scan displaces a waiting one.
public enum UploadTextScan {
    /// What the overlay needs from one scan.
    public struct Result: Sendable, Equatable {
        public let matches: [SecretMatch]
        /// The payload's size once redacted, or nil when there is nothing to redact. Computed on
        /// the lane's thread, which already holds the text and the ranges into it, so the overlay
        /// can state the true upload size without re-scanning or keeping a second copy alive.
        public let redactedBytes: Int?
    }

    /// The scan itself, synchronous and uncapped. Runs on the lane; exposed for tests.
    public static func scan(_ text: String) -> Result {
        let matches = SecretDetector.scanIgnoringSizeCap(text)
        let redactedBytes = matches.isEmpty
            ? nil
            : SecretRedactor.redact(text, matches: matches).utf8.count
        return Result(matches: matches, redactedBytes: redactedBytes)
    }

    /// `static`, not per overlay: "a per-instance lane is not a lane" (#46) — the overlay is
    /// rebuilt on every ⌘⇧U.
    static let lane = SingleSlotLane<String, Result>(label: "net.scromp.Pastefix.upload.text-scan") {
        scan($0)
    }

    /// The scan's result, or nil when a newer scan displaced this one before it started.
    ///
    /// Only starting a scan supersedes anything. An overlay being dismissed deliberately does not:
    /// when ⌘⇧U replaces one overlay with another, the old one's teardown can run after the new
    /// one has started its scan, and superseding then would strand the new overlay on "Scanning…".
    /// A dismissed overlay's result is dropped by its own task's cancellation instead.
    public static func run(_ text: String) async -> Result? {
        await lane.run(text, generation: lane.nextGeneration())
    }
}
