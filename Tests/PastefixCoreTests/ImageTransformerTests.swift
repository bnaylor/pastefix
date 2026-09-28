import Testing
import Foundation
@testable import PastefixCore

private struct TextOnly: Transformer {
    let id = "test.text"; let name = "Text"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text.uppercased() }
}

private struct Flipper: ImageTransformer {
    let id = "test.image"; let name = "Flipper"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    let lane = ImageTransformLane.makeLane(label: "test.flipper")
    func transformImage(_ png: Data) throws -> TransformOutput { .image(Data(png.reversed()), note: "flipped") }
}

private struct StrippedDefault: ImageTransformer {
    let id = "test.default-lane"; let name = "Default"; let requiresRichInput = false
    let source: TransformerSource = .builtin
    func transformImage(_ png: Data) throws -> TransformOutput { .nothingToDo("") }
}

@Suite("the image transform interface")
struct ImageTransformerTests {
    @Test("an ordinary transform's `transform` is its `apply`, as text")
    func defaultWrapsApply() async throws {
        let out = try await TextOnly().transform(TransformInput(text: "abc"))
        #expect(out == .text("ABC"))
    }

    // The coordinator calls through `any Transformer`. If `transform` were only an extension
    // method it would dispatch statically to the text default, and an image transform's own
    // body would never run.
    @Test("an image transform runs its own body through `any Transformer`")
    func dynamicDispatch() async throws {
        let t: any Transformer = Flipper()
        let out = try await t.transform(TransformInput(text: "", image: Data([1, 2, 3])))
        #expect(out == .image(Data([3, 2, 1]), note: "flipped"))
        #expect(t.acceptedForms == [.image] && t.timeout == 10)
    }

    @Test("a production image transform uses the shared lane; a stub can bring its own")
    func laneSelection() {
        #expect(StrippedDefault().lane === ImageTransformLane.shared)
        #expect(Flipper().lane !== ImageTransformLane.shared)
    }

    @Test("an image transform given no image refuses rather than guessing")
    func noImage() async {
        await #expect(throws: TransformError.self) {
            try await Flipper().transform(TransformInput(text: "abc"))
        }
    }

    @Test("a job displaced from the lane throws CancellationError and never runs")
    func displacedJob() async throws {
        let lane = ImageTransformLane.makeLane(label: "test.displaced")
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let first = Task { try await ImageTransformLane.run(on: lane) { started.signal(); gate.wait(); return .nothingToDo("first") } }
        #expect(Self.waited(started))
        let displaced = Task { try await ImageTransformLane.run(on: lane) { .nothingToDo("displaced") } }
        #expect(await eventually { lane.waitingGeneration != nil })
        let newest = Task { try await ImageTransformLane.run(on: lane) { .nothingToDo("newest") } }
        await #expect(throws: CancellationError.self) { try await displaced.value }
        gate.signal()
        #expect(try await first.value == .nothingToDo("first"))
        #expect(try await newest.value == .nothingToDo("newest"))
    }

    /// `DispatchSemaphore.wait` is unavailable in async code; a synchronous wrapper is the same
    /// indirection `SingleSlotLaneTests.Probe` uses.
    private static func waited(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }
}
