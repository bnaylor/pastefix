import Foundation

/// A `UserDefaults` that never touches ~/Library/Preferences (#85).
///
/// Its suite is named by an **absolute path** inside a private temp folder, so the backing plist
/// lives there and `remove()` deletes it for good. A *named* suite leaks: `cfprefsd` writes the
/// emptied domain's plist back into ~/Library/Preferences several seconds after
/// `removePersistentDomain` and any file removal — measured (Plan 18, #68), and 334 of them had
/// accumulated from this suite before this helper existed. Every test that needs defaults gets one
/// of these; `DefaultsIsolationTests` fails if a test file creates a suite any other way.
final class IsolatedDefaults {
    let defaults: UserDefaults
    let directory: URL
    private let suite: String

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastefix-defaults-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = directory.appendingPathComponent("defaults").path
        defaults = UserDefaults(suiteName: suite)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
