import Foundation

/// A folder under $TMPDIR named `<prefix>-<UUID>`, removed with its contents when this value goes
/// away — at the end of the test, and also when a test throws part-way, which a forgotten or
/// skipped `defer` doesn't cover. Hold it for as long as the test uses the folder (a local `let`,
/// or a stored property of the suite, which Swift Testing recreates per test).
///
/// Tests used to create folders here and never remove them: thousands leaked on each machine
/// (2,668 here, 2,360 on the work laptop, 2026-09-30), and a huge $TMPDIR slows every listing of it.
final class TemporaryDirectory {
    let url: URL

    init(_ prefix: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
