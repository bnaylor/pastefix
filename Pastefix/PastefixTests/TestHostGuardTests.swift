import Testing
import AppKit
import Foundation
import PastefixAppCore
@testable import Pastefix

/// The app is this bundle's test host: it has been launched for real, on the developer's machine.
/// These pin that the real app was never started.
@Suite("Test host")
struct TestHostGuardTests {
    @Test("detection recognises this host — and reports which XCTest variables it saw")
    func detectsHost() {
        let env = ProcessInfo.processInfo.environment
        let seen = TestHostDetection.environmentKeys.filter { !(env[$0] ?? "").isEmpty }
        // Recorded so the spec can say which variables this Xcode actually sets.
        print("PASTEFIX_TESTHOST_ENV seen=\(seen)")
        #expect(!seen.isEmpty)
        #expect(TestHostDetection.isHostingTests())
    }

    @Test("the real app was never started: no AppDelegate exists")
    func appNeverStarted() {
        #expect(!(NSApp.delegate is AppDelegate))
    }
}
