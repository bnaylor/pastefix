import Foundation

/// A transform whose input is the session's image (Plan 20). Its body is synchronous and runs on
/// a lane: a CG decode cannot be cancelled, so a cancelled apply (Esc, a new summon) keeps
/// decoding, and without one process-wide lane repeated attempts would stack decodes of hundreds
/// of MB — the #46/#48 lesson.
public protocol ImageTransformer: Transformer {
    /// The lane this transform's body runs on: `ImageTransformLane.shared` for every real
    /// transform. A requirement so tests can give each stub its own — all package tests share one
    /// process, and stubs on the shared lane would displace each other's waiting jobs. (A
    /// task-local override would not survive `Deadline.run`, which detaches its body.)
    var lane: ImageTransformLane.Lane { get }
    /// The transform itself, given the current image entry's PNG. Runs on the lane, off the main
    /// actor. The coordinator has already refused an image over the pixel ceiling.
    func transformImage(_ png: Data) throws -> TransformOutput
}

public extension ImageTransformer {
    var lane: ImageTransformLane.Lane { ImageTransformLane.shared }
    var acceptedForms: Set<ContentForm> { [.image] }
    /// A 20 MP decode alone is ~1 s; the text default of 3 s is too tight for decode + encode.
    var timeout: TimeInterval { 10 }

    /// Never called: the coordinator calls `transform`, and `acceptedForms` keeps an image
    /// transform out of text sessions. Throws rather than returning text nobody asked for.
    func apply(_ input: TransformInput) async throws -> String {
        throw TransformError.invalidInput("\(name) needs an image.")
    }

    func transform(_ input: TransformInput) async throws -> TransformOutput {
        guard let png = input.image else { throw TransformError.invalidInput("\(name) needs an image.") }
        return try await ImageTransformLane.run(on: lane) { try self.transformImage(png) }
    }
}

/// The lane image transforms run down, process-wide: one running, one waiting, and a newer job
/// displaces a waiting one. It is the third such lane (history capture's `TIFFConversionSlot` and
/// upload preparation's are the others), so up to three uncancellable 25 MP decodes can run at
/// once — stated in the spec, and deliberately not merged: a transform displacing a waiting upload
/// preparation would strand that card in its `superseded` state.
public enum ImageTransformLane {
    /// One job: its body, run on the lane's queue.
    public struct Job: Sendable {
        let body: @Sendable () -> Result<TransformOutput, any Error>
    }
    public typealias Lane = SingleSlotLane<Job, Result<TransformOutput, any Error>>

    /// The lane every real image transform uses.
    public static let shared = makeLane(label: "net.scromp.Pastefix.image-transform")

    public static func makeLane(label: String) -> Lane { Lane(label: label) { $0.body() } }

    /// Runs `body` on `lane`. Throws `CancellationError` when a newer job displaced this one
    /// before it started — its caller has been superseded, so there is no one to answer.
    public static func run(on lane: Lane,
                           _ body: @escaping @Sendable () throws -> TransformOutput) async throws -> TransformOutput {
        let job = Job { Result { try body() } }
        guard let result = await lane.run(job, generation: lane.nextGeneration()) else {
            throw CancellationError()
        }
        return try result.get()
    }
}

/// An image transform that acts on a selected region (crop now; redact later). The region comes in
/// on `TransformInput.region`, and is nil when nothing is selected, which the transform explains.
public protocol RegionImageTransformer: ImageTransformer {
    func transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput
}

public extension RegionImageTransformer {
    func transformImage(_ png: Data) throws -> TransformOutput { try transformImage(png, region: nil) }

    func transform(_ input: TransformInput) async throws -> TransformOutput {
        guard let png = input.image else { throw TransformError.invalidInput("\(name) needs an image.") }
        let region = input.region
        return try await ImageTransformLane.run(on: lane) { try self.transformImage(png, region: region) }
    }
}
