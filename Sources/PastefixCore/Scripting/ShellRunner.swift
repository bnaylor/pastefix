import Foundation

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

        try process.run()

        // Feed stdin on a background thread so a child that never reads stdin
        // (or fills stderr before consuming stdin) cannot block the caller.
        let stdinData = input.data(using: .utf8) ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Watchdog: terminate on timeout.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
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
            let stderr = String(data: errBytes, encoding: .utf8) ?? ""
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
}
