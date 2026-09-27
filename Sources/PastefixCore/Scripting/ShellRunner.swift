import Foundation
import Darwin

public enum ShellRunner {
    /// Runs the script with `input` on stdin and returns its stdout.
    ///
    /// **Cancelling the calling task stops the script** (#56): the whole process group gets the
    /// watchdog's SIGTERM-then-SIGKILL, and the run throws `CancellationError`. Before, a
    /// cancelled apply abandoned the script, which ran on until it finished or timed out — and
    /// Esc → summon → apply could stack them.
    ///
    /// **Waiting for exit is a suspension, not a blocked thread.** `waitUntilExit()` held a
    /// cooperative-pool thread for as long as the child lived after closing its output (measured:
    /// 0.00 s for an ordinary script, 3.01 s for one that closes stdout/stderr and lingers 3 s),
    /// so enough such runs at once starved every other async task in the process.
    public static func run(scriptURL: URL, input: String, timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = scriptURL          // shebang honored by the kernel
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Put the child in its own process group so that signals can target the
        // entire group (shell + any grandchild subprocesses like `sleep`).
        // Without this, killing only the shell leaves grandchildren holding the
        // pipe write ends open, and readToEnd never sees EOF.
        process.qualityOfService = .userInitiated
        // Installed before `run()`, as `Process` requires, so an instant exit is not missed.
        let exited = ExitSignal()
        process.terminationHandler = { _ in exited.fire() }
        try process.run()
        let pid = process.processIdentifier
        // Process already spawns the child into its own group (pgid == pid; measured 400/400 in
        // the #100 review), so `kill(-pid, …)` reaches it either way. This is belt-and-braces, and
        // fails harmlessly (EACCES) if the child has already exec'd.
        setpgid(pid, pid)

        // Feed stdin on a background thread so a child that never reads stdin
        // (or fills stderr before consuming stdin) cannot block the caller.
        let stdinData = input.data(using: .utf8) ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Watchdog: send SIGTERM to the process group on timeout; escalate to
        // SIGKILL after a 0.5 s grace period so scripts trapping SIGTERM cannot
        // hang the caller indefinitely.  Signalling the group also reaps any
        // grandchild processes (e.g. `sleep`) that hold the pipe write ends,
        // ensuring readToEnd sees EOF promptly.
        // The SIGKILL escalation is on DispatchQueue rather than a Task so it does not depend on
        // a cooperative thread being free.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard process.isRunning else { return }
            terminateGroup(pid, of: process)
        }

        return try await withTaskCancellationHandler {
            try await collect(process, exited: exited, stdout: stdoutPipe, stderr: stderrPipe,
                              watchdog: watchdog)
        } onCancel: {
            terminateGroup(pid, of: process)
        }
    }

    /// SIGTERM to the whole group, then SIGKILL after a 0.5 s grace period so a script trapping
    /// SIGTERM cannot hang the caller. The timeout and cancellation both end a run this way.
    private static func terminateGroup(_ pid: pid_t, of process: Process) {
        kill(-pid, SIGTERM)                                 // SIGTERM → whole group
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                kill(-pid, SIGKILL)                        // SIGKILL → whole group
            }
        }
    }

    private static func collect(_ process: Process, exited: ExitSignal, stdout stdoutPipe: Pipe,
                                stderr stderrPipe: Pipe, watchdog: Task<Void, Error>) async throws -> String {
        // Drain BOTH pipes concurrently before waiting for exit, to prevent deadlock.
        // Sequential draining would hang if the child fills the stderr pipe buffer
        // (~64 KB) while stdout is still being read, because the child blocks on
        // write and never exits, so stdout never hits EOF.
        async let outData = readToEnd(stdoutPipe.fileHandleForReading)
        async let errData = readToEnd(stderrPipe.fileHandleForReading)
        let (outBytes, errBytes) = await (outData, errData)
        await exited.wait()
        watchdog.cancel()
        // Before the status checks: a cancelled run was ended by our own signal, which would
        // otherwise read as a timeout below.
        try Task.checkCancellation()

        // NOTE: terminationReason == .uncaughtSignal is used as the timeout signal
        // because the watchdog sends SIGTERM via process.terminate(). An unrelated
        // fatal signal (e.g. SIGBUS from a crash) would also be misclassified as
        // timeout. This is an acceptable trade-off for clipboard-sized scripts.
        if process.terminationReason == .uncaughtSignal {
            throw TransformError.timeout
        }
        if process.terminationStatus != 0 {
            let rawStderr = String(data: errBytes, encoding: .utf8) ?? ""
            let stderr = Self.truncatedTail(rawStderr, limit: 8 * 1024)
            throw TransformError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
        }
        return String(data: outBytes, encoding: .utf8) ?? ""
    }

    /// The child's exit, as something to await: `terminationHandler` fires it, `wait()` suspends
    /// until it has fired (or returns at once if it already has).
    private final class ExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var hasExited = false
        private var waiter: CheckedContinuation<Void, Never>?

        func fire() {
            lock.lock()
            hasExited = true
            let resume = waiter
            waiter = nil
            lock.unlock()
            resume?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasExited {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// Returns the last `limit` UTF-8 bytes of `s`, prefixed with a truncation marker when trimmed.
    static func truncatedTail(_ s: String, limit: Int) -> String {
        let encoded = Array(s.utf8)
        guard encoded.count > limit else { return s }
        let tail = encoded.suffix(limit)
        let marker = "…(truncated)…\n"
        return marker + (String(bytes: tail, encoding: .utf8) ?? String(tail.map { Character(Unicode.Scalar($0)) }))
    }
}
