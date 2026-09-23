import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

private struct FakeTransformer: Transformer {
    let id: String
    let name: String
    let requiresRichInput: Bool
    let source: TransformerSource = .builtin
    let behavior: @Sendable (TransformInput) async throws -> String
    func apply(_ input: TransformInput) async throws -> String { try await behavior(input) }
}

private struct Arming: OutputModeTransformer {
    let id = "t.arm"
    let name = "Arm"
    let requiresRichInput = false
    let source = TransformerSource.builtin
    let outputMode = OutputMode.renderedMarkdown
    func apply(_ i: TransformInput) async throws -> String { i.text }
}

private struct FailingArming: OutputModeTransformer {
    let id = "t.fail"
    let name = "Fail"
    let requiresRichInput = false
    let source = TransformerSource.builtin
    let outputMode = OutputMode.renderedMarkdown
    func apply(_ i: TransformInput) async throws -> String { throw TransformError.invalidInput("no") }
}

@Suite struct TransformCoordinatorTests {
    private func doc(_ text: String, rich: Bool = false) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: rich ? Data([1]) : nil))
    }

    @Test func applySuccessPushesResult() async {
        let t = FakeTransformer(id: "x", name: "X", requiresRichInput: false) { input in
            input.text.uppercased()
        }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .applied)
        #expect(updated.working == "HI")
        #expect(updated.canUndo == true)
    }

    @Test func applyUnchangedReportsUnchanged() async {
        let t = FakeTransformer(id: "id", name: "Id", requiresRichInput: false) { $0.text }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .unchanged)
        #expect(updated.canUndo == false)
    }

    /// An identity transform still pushes, so detection resyncs to a secret the user typed in
    /// after the last discrete event — `setWorking` deliberately doesn't re-detect, and before
    /// this the coordinator returned `.unchanged` without ever calling `pushState`.
    @Test func applyUnchangedStillRedetects() async {
        var d = doc("nothing here")
        d.setWorking("aws key AKIAIOSFODNN7EXAMPLE")
        #expect(d.secretMatches.isEmpty)
        let t = FakeTransformer(id: "id", name: "Id", requiresRichInput: false) { $0.text }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: d)
        #expect(outcome == .unchanged)
        #expect(updated.isDetecting)
        var settled = updated
        settled.applyDetection(DetectionResult.compute(settled.working), revision: settled.detectionRevision)
        #expect(settled.secretMatches.count == 1)
        #expect(settled.detectedKinds.contains(.secret))
        #expect(updated.canUndo == false)
        #expect(updated.canRedo == false)
    }

    @Test func applyFailureReturnsMessageAndLeavesDocument() async {
        let t = FakeTransformer(id: "f", name: "F", requiresRichInput: false) { _ in
            throw TransformError.timeout
        }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("The transform timed out."))
        #expect(updated.working == "hi")
        #expect(updated.canUndo == false)
    }

    @Test func richTransformPassesOriginRTFD() async {
        let t = FakeTransformer(id: "r", name: "R", requiresRichInput: true) { input in
            input.richRTFD == nil ? "NO-RICH" : "HAS-RICH"
        }
        let (updated, _) = await TransformCoordinator.apply(t, to: doc("hi", rich: true))
        #expect(updated.working == "HAS-RICH")
    }

    @Test func isEnabledGatesRichOnOriginContent() {
        let rich = FakeTransformer(id: "r", name: "R", requiresRichInput: true) { $0.text }
        let plain = FakeTransformer(id: "p", name: "P", requiresRichInput: false) { $0.text }
        #expect(TransformCoordinator.isEnabled(rich, for: doc("x", rich: false)) == false)
        #expect(TransformCoordinator.isEnabled(rich, for: doc("x", rich: true)) == true)
        #expect(TransformCoordinator.isEnabled(plain, for: doc("x", rich: false)) == true)
    }

    @Test func errorMessageRichInputUnavailable() async {
        let t = FakeTransformer(id: "f", name: "F", requiresRichInput: false) { _ in
            throw TransformError.richInputUnavailable
        }
        let (_, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("No rich text available to convert."))
    }

    @Test func errorMessageScriptFailed() async {
        let t = FakeTransformer(id: "f", name: "F", requiresRichInput: false) { _ in
            throw TransformError.scriptFailed("Something went wrong")
        }
        let (_, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("Script error: Something went wrong"))
    }

    @Test func errorMessageNonZeroExitWithStderr() async {
        let t = FakeTransformer(id: "f", name: "F", requiresRichInput: false) { _ in
            throw TransformError.nonZeroExit(code: 42, stderr: "error output")
        }
        let (_, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("Script failed (exit 42): error output"))
    }

    @Test func errorMessageNonZeroExitEmptyStderr() async {
        let t = FakeTransformer(id: "f", name: "F", requiresRichInput: false) { _ in
            throw TransformError.nonZeroExit(code: 1, stderr: "")
        }
        let (_, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("Script failed (exit 1)."))
    }

    @Test func invalidInputLeavesDocumentAndReportsMessage() async {
        let t = FakeTransformer(id: "bad", name: "Bad", requiresRichInput: false) { _ in
            throw TransformError.invalidInput("Not valid Base64 text")
        }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("Not valid Base64 text"))
        #expect(updated.working == "hi")
        #expect(updated.canUndo == false)
    }

    @Test func armingTransformAppliesWithoutTextChange() async {
        let doc = PasteDocument(origin: ClipboardSnapshot(plainText: "# x", richRTFD: nil))
        let (out, outcome) = await TransformCoordinator.apply(Arming(), to: doc)
        #expect(outcome == .applied && out.outputMode == .renderedMarkdown && out.working == "# x" && !out.canUndo)
    }

    @Test func failingArmingLeavesModePlain() async {
        let doc = PasteDocument(origin: ClipboardSnapshot(plainText: "# x", richRTFD: nil))
        let (out, outcome) = await TransformCoordinator.apply(FailingArming(), to: doc)
        #expect(out.outputMode == .plain); if case .failed = outcome {} else { Issue.record("expected failure") }
    }
}
