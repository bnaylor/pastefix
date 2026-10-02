import Testing
import Foundation
@testable import PastefixCore

@Suite struct ShellRunnerTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    /// A script written to a temp folder, for shapes the bundled fixtures don't cover.
    private func tempScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfx-shell-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // A script whose stdout isn't UTF-8 text (a stray binary tool, a wrong encoding) used to come
    // back as "" with no error, and the empty string replaced the buffer. It is a failure.
    @Test func outputThatIsNotUTF8IsAFailure() async throws {
        let url = try tempScript("printf 'caf\\351\\n'\n")   // Latin-1 é: not UTF-8
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: TransformError.scriptFailed("the script's output isn't UTF-8 text")) {
            try await ShellRunner.run(scriptURL: url, input: "", timeout: 5)
        }
    }

    /// A script that exits without reading its input (an early error, a script that just prints)
    /// closed the pipe under the stdin write, and the write raised SIGPIPE, which nothing ignored:
    /// it killed the process — the test runner here, Pastefix itself in the app. Input bigger
    /// than the pipe buffer (64 KB) makes the race certain: the write blocks until the script
    /// has exited. Found as a load-only crash of the parallel suite (signal 13) during #21.
    @Test func aScriptThatIgnoresItsInputDoesNotKillUs() async throws {
        let url = try tempScript("echo done\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = String(repeating: "x", count: 1_048_576)
        for _ in 0..<3 {
            #expect(try await ShellRunner.run(scriptURL: url, input: input, timeout: 5) == "done\n")
        }
    }

    @Test func emptyOutputIsStillEmpty() async throws {
        let url = try tempScript("cat > /dev/null\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try await ShellRunner.run(scriptURL: url, input: "x", timeout: 5) == "")
    }

    // #56: cancelling the apply stops the script — the whole process group, grandchildren too —
    // instead of abandoning it to run until it finishes or times out.
    @Test func cancellationStopsTheScriptAndItsChildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pfx-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let url = try tempScript("sleep 30 &\necho $! > '\(pidFile.path)'\nwait\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let run = Task { try await ShellRunner.run(scriptURL: url, input: "", timeout: 30) }
        var grandchild: pid_t = 0
        for _ in 0..<200 where grandchild == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            grandchild = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        #expect(grandchild > 0, "fixture: the script must have started its sleep")
        let start = ContinuousClock.now
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(ContinuousClock.now - start < .seconds(3), "cancel must not wait out the script")
        // kill(pid, 0) probes without signalling; ESRCH means the process no longer exists.
        var gone = false
        for _ in 0..<100 where !gone {
            gone = kill(grandchild, 0) != 0 && errno == ESRCH
            if !gone { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(gone, "the script's child survived cancellation")
    }

    // #56: waiting for exit is a suspension, not a blocked thread. A script that closes its output
    // and keeps running used to hold a cooperative-pool thread in `waitUntilExit()` until it
    // exited (measured: 3.01 s for a 3 s linger, 0.00 s for an ordinary script). Enough of them
    // at once starved every other async task in the process, detection included.
    @Test func lingeringScriptsDoNotStarveThePool() async throws {
        let url = try tempScript("exec >&- 2>&-\nsleep 5\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let runs = (0..<count).map { _ in
            Task { _ = try? await ShellRunner.run(scriptURL: url, input: "", timeout: 10) }
        }
        // The measurement is sleep overshoot: resuming needs a free cooperative thread, so while
        // the runs pin them all, a sleep ends late by as long as they block. Sampled across the
        // whole linger, keeping the worst, because *when* the pool is pinned moves with how long
        // launching the processes takes — a single 300 ms sleep woke before the pinning began in
        // one of three runs against the blocking runner. (The first draft measured a probe task
        // started after the sleep, by which point the starvation was over: it could not fail.)
        var worst = Duration.zero
        for _ in 0..<60 {
            let start = ContinuousClock.now
            try await Task.sleep(nanoseconds: 100_000_000)
            worst = max(worst, ContinuousClock.now - start - .milliseconds(100))
        }
        for run in runs { await run.value }
        // The bound sits between two measured numbers, not near either. A blocking runner pins
        // the pool for the whole 5 s linger (overshoot ≈ 5 s); in the full parallel suite, other
        // CPU-heavy tests alone produce up to ~1.4 s of overshoot (2.8 s with every core
        // saturated by other processes, when every timing test in the suite fails). The first
        // version lingered 2 s against a 1 s bound — inside that noise — and failed 3 runs in 5
        // on a correct runner.
        #expect(worst < .milliseconds(3500), "a task waited \(worst) for a thread")
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

    @Test func sigtermTrappingScriptStillTimesOut() async throws {
        let url = try fixture("trap.sh")
        let start = Date()
        await #expect(throws: TransformError.timeout) {
            try await ShellRunner.run(scriptURL: url, input: "x", timeout: 1)
        }
        let elapsed = Date().timeIntervalSince(start)
        // Must resolve well before the 30-second sleep — SIGKILL escalation enforces this.
        #expect(elapsed < 5, "Elapsed \(elapsed)s — SIGKILL did not fire in time")
    }

    @Test func shellTransformerUsesMetadataName() {
        let url = URL(fileURLWithPath: "/tmp/foo.sh")
        let t = ShellTransformer(url: url, metadata: ScriptMetadata(name: "Shout"), timeout: 3)
        #expect(t.name == "Shout")
        #expect(t.id == "shell:foo.sh")
        #expect(t.source == .shell(url))
    }
}
