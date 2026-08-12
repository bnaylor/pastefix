import Foundation
import Darwin

public enum ShellRunner {
    public static func run(scriptURL: URL, input: String, timeout: TimeInterval) async throws -> String {
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
        try process.run()
        let pid = process.processIdentifier
        // Move the child into its own process group (pgid == pid).
        // Ignore EPERM if the child already exec'd and set its own group.
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
        // Use DispatchQueue (not Task) for escalation so the SIGKILL fires on
        // a real OS thread even while waitUntilExit() blocks a cooperative thread.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard process.isRunning else { return }
            kill(-pid, SIGTERM)                             // SIGTERM → whole group
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    kill(-pid, SIGKILL)                    // SIGKILL → whole group
                }
            }
        }

        // Drain BOTH pipes concurrently before waitUntilExit to prevent deadlock.
        // Sequential draining would hang if the child fills the stderr pipe buffer
        // (~64 KB) while stdout is still being read, because the child blocks on
        // write and never exits, so stdout never hits EOF.
        async let outData = readToEnd(stdoutPipe.fileHandleForReading)
        async let errData = readToEnd(stderrPipe.fileHandleForReading)
        let (outBytes, errBytes) = await (outData, errData)
        process.waitUntilExit()
        watchdog.cancel()

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
