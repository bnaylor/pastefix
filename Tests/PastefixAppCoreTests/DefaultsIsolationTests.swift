import Testing
import Foundation

/// #85: tests leaked a `UserDefaults` domain per run into ~/Library/Preferences — 334 on one
/// machine. The fix is two helpers whose suites are named by a path inside a temp folder
/// (`IsolatedDefaults` here, `ModelFixture` in the app tests). A leak cannot be caught by a test
/// at runtime (cfprefsd re-flushes seconds after the process is done), so this pins it statically:
/// no other test file may create a suite.
@Suite("Defaults isolation")
struct DefaultsIsolationTests {
    static let sanctioned: Set<String> = ["IsolatedDefaults.swift", "ModelFixture.swift", "DefaultsIsolationTests.swift"]

    @Test("only the isolation helpers create a UserDefaults suite")
    func onlyHelpersCreateSuites() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for root in ["Tests", "Pastefix/PastefixTests"] {
            let dir = repo.appendingPathComponent(root)
            guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                scanned += 1
                guard !Self.sanctioned.contains(url.lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains("UserDefaults(suiteName") else { continue }
                offenders.append(url.path.replacingOccurrences(of: repo.path + "/", with: ""))
            }
        }
        #expect(scanned > 20, "scanned only \(scanned) test files — is the repo path right?")
        #expect(offenders.isEmpty, "create defaults through IsolatedDefaults, not UserDefaults(suiteName:): \(offenders)")
    }
}
