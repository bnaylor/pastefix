import Testing
import Foundation
@testable import PastefixCore

@Suite struct ShellRunnerTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    @Test func pipesStdinToStdout() async throws {
        let url = try fixture("upper.sh")
        let out = try await ShellRunner.run(scriptURL: url, input: "hello", timeout: 5)
        #expect(out.trimmingCharacters(in: .newlines) == "HELLO")
    }

    @Test func nonZeroExitThrowsWithStderr() async throws {
        let url = try fixture("fail.sh")
        await #expect(throws: TransformError.nonZeroExit(code: 3, stderr: "boom\n")) {
            try await ShellRunner.run(scriptURL: url, input: "x", timeout: 5)
        }
    }

    @Test func timeoutThrows() async throws {
        let url = try fixture("sleep.sh")
        await #expect(throws: TransformError.timeout) {
            try await ShellRunner.run(scriptURL: url, input: "x", timeout: 1)
        }
    }

    @Test func largeStderrDoesNotDeadlock() async throws {
        let url = try fixture("bigerr.sh")
        // bigerr.sh writes ~320 KB to stderr (5000 * 65-byte lines), far exceeding
        // the ~64 KB pipe buffer. Sequential pipe draining would deadlock here;
        // concurrent draining must return promptly with nonZeroExit, not timeout.
        do {
            _ = try await ShellRunner.run(scriptURL: url, input: "", timeout: 10)
            Issue.record("Expected nonZeroExit(code:3) but run() returned successfully")
        } catch TransformError.nonZeroExit(let code, _) {
            #expect(code == 3)
        } catch TransformError.timeout {
            Issue.record("Got .timeout — pipe drain deadlocked or watchdog fired (the deadlock bug is not fixed)")
        }
    }

    @Test func shellTransformerUsesMetadataName() {
        let url = URL(fileURLWithPath: "/tmp/foo.sh")
        let t = ShellTransformer(url: url, metadata: ScriptMetadata(name: "Shout"), timeout: 3)
        #expect(t.name == "Shout")
        #expect(t.id == "shell:foo.sh")
        #expect(t.source == .shell(url))
    }
}
