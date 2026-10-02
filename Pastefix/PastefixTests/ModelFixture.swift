import Testing
import AppKit
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// An `AppModel` wired to nothing of the user's (#68). Per test, not per suite: Swift Testing runs
/// suites in parallel in one process, which is how #85's leaked defaults domains happened.
///
/// - a uniquely named pasteboard, released on teardown — never `.general`;
/// - a unique `UserDefaults` suite, whose persistent domain is removed on teardown;
/// - the scripts directory pointed at an empty temp folder, so the registry never discovers or
///   runs the developer's real scripts;
/// - history in a temp folder.
///
/// `finish()` also asserts the general pasteboard's `changeCount` did not move while the test ran:
/// the backstop that no path under test reached the user's clipboard.
@MainActor
final class ModelFixture {
    let pasteboard: NSPasteboard
    let settings: SettingsStore
    let history: HistoryStore
    let model: AppModel
    let directory: URL
    private let suite: String
    private let generalAtStart: Int

    init() throws {
        let id = UUID().uuidString
        generalAtStart = NSPasteboard.general.changeCount
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pastefix-apptests-\(id)", isDirectory: true)
        // The suite is named by an absolute path inside this test's own temp folder, so its plist
        // lives there and is removed with the folder. A named suite (net.scromp.PastefixTests.<id>)
        // leaks: cfprefsd recreates the emptied plist in ~/Library/Preferences several seconds
        // after `removePersistentDomain` and any file removal — measured, a file per test per run.
        suite = directory.appendingPathComponent("defaults").path
        let scripts = directory.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(scripts.path, forKey: "pastefix.scriptsDirectoryPath")
        settings = SettingsStore(defaults: defaults)
        settings.scriptsDirectoryPath = scripts.path
        history = HistoryStore(directory: directory.appendingPathComponent("history", isDirectory: true),
                               limits: HistoryLimits(maxItems: 50))
        pasteboard = NSPasteboard(name: NSPasteboard.Name("net.scromp.PastefixTests.\(id)"))
        pasteboard.clearContents()
        model = AppModel(settings: settings, history: history, pasteboard: pasteboard)
    }

    func finish() {
        #expect(NSPasteboard.general.changeCount == generalAtStart,
                "the general clipboard changed during this test: a test path reached it, or something else on the machine copied while the test ran")
        pasteboard.releaseGlobally()
        // The suite's plist lives inside `directory` (see `init`), so removing the folder removes it.
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Puts `items` on this fixture's pasteboard as one item, as a copy from some app would.
    func copy(_ representations: [NSPasteboard.PasteboardType: Data]) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in representations { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
    }

    func copy(text: String) { copy([.string: Data(text.utf8)]) }

    /// Waits for a condition, polling every 10 ms up to a 10 s wall-clock deadline. A passing test
    /// returns as soon as the condition holds, so the ceiling only costs time when a test is failing;
    /// it was 300 polls (~3 s), which a loaded machine overran (#132: a 24.8 s hosted run, load ~8).
    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

enum Pixels {
    /// A PNG or TIFF of a solid image. `compressedTIFF` keeps a huge-dimension TIFF small on disk,
    /// so a pixel-ceiling test does not allocate the pixels it is testing the refusal of.
    static func encoded(width: Int, height: Int, type: String, compressedTIFF: Bool = false) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = compressedTIFF
            ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] : [:]
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
