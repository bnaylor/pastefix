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

        // Feed stdin then close so the child sees EOF.
        if let data = input.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Watchdog: terminate on timeout.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        // Drain pipes on background threads to avoid deadlock on large output.
        let outData = await readToEnd(stdoutPipe.fileHandleForReading)
        let errData = await readToEnd(stderrPipe.fileHandleForReading)
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw TransformError.timeout
        }
        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw TransformError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
        }
        return String(data: outData, encoding: .utf8) ?? ""
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
