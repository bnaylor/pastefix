import Foundation

/// Whether Pastefix.app has been launched as a **test host** (#68).
///
/// A hosted test run launches the real app, on the developer's own machine. Unguarded, it would
/// register global hotkeys (colliding with an installed Pastefix), start the clipboard monitor
/// (reading the real clipboard, writing the real history), and start Sparkle. The app delegate asks
/// this at launch and, when it answers true, starts none of it.
///
/// **Any** of the four variables XCTest reads counts (found in Xcode's XCTestCore binary): which
/// ones a given Xcode sets for a macOS hosted run — XCTest or Swift Testing, parallel or not —
/// is not documented, and an earlier version keyed on `XCTestConfigurationFilePath` alone came
/// back false in a real hosted run and let the app launch in full. Accepting any of them fails
/// closed. `DYLD_*` is deliberately not used: the hardened runtime strips those.
///
/// Decided once, at `main`, before any app object exists — see `PastefixEntry`.
public enum TestHostDetection {
    public static let environmentKeys = [
        "XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath", "XCTestBundleInjectPath",
    ]

    public static func isHostingTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environmentKeys.contains { !(environment[$0] ?? "").isEmpty }
    }
}
