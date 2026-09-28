import Foundation
import PastefixCore

/// One preparation per session's image: a rebuilt owner gets the task already in flight, not a
/// new decode (#48).
///
/// `PanelView` rebuilds the ⌘⇧U overlay on every repeat press, and a CG decode cannot be
/// cancelled. The lane (`SingleSlotLane`) bounds how many preparations run at once *across*
/// sessions; this bounds how many a single session starts, which is one. Without it, each rebuilt
/// overlay would mint a new lane generation and requeue the same bytes — bounded, but the user's
/// hammering would keep superseding the job it was waiting on.
///
/// Keyed by the session generation **and** the bytes. The generation alone is not enough: ⌘R
/// (`AppModel.refresh`) replaces the document's image without starting a new session, and a
/// cache keyed only on the generation would hand the new image's overlay the old image's result —
/// a `SanitizedImage` of the picture the user is no longer looking at. `Data ==` compares length
/// first, so the common "same session, same bytes" hit is one memcmp on bytes already resident.
@MainActor
public final class SessionPreparationCache<Output: Sendable> {
    public typealias Prepared = Task<Output?, Never>

    private let lane: SingleSlotLane<Data, Output>
    private var entry: (generation: Int, input: Data, task: Prepared)?

    public init(lane: SingleSlotLane<Data, Output>) {
        self.lane = lane
    }

    /// The cached task for these bytes in this session, or a new one queued on the lane. A new
    /// one supersedes whatever the lane has waiting (the lane's own rule: minting a generation
    /// abandons unstarted work), which is right — anything waiting belongs to an image nobody is
    /// looking at any more.
    public func preparation(for input: Data, generation: Int) -> Prepared {
        if let entry, entry.generation == generation, entry.input == input {
            return entry.task
        }
        let lane = lane
        let laneGeneration = lane.nextGeneration()
        let task = Task { await lane.run(input, generation: laneGeneration) }
        entry = (generation, input, task)
        return task
    }

    /// Drops the entry at a session boundary, and skips its job if it has not started yet. A job
    /// that has started runs to completion (a decode cannot be interrupted); its result is simply
    /// no longer anyone's.
    public func clear() {
        guard entry != nil else { return }
        entry = nil
        _ = lane.nextGeneration()
    }

    /// For tests.
    var hasEntry: Bool { entry != nil }
}
