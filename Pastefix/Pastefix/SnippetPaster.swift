import AppKit
import ApplicationServices

/// Puts a snippet on the clipboard and pastes it into another app by posting ⌘V. Accessibility
/// permission is required to post the key event; Pastefix uses it for nothing else — no event
/// tap, no key observation.
@MainActor
enum SnippetPaster {
    enum Outcome { case pasted, copiedOnly }
    private static var promptedThisLaunch = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt at most once per launch. Returns the current trust state.
    @discardableResult
    static func ensureTrusted() -> Bool {
        if isTrusted { return true }
        guard !promptedThisLaunch else { return false }
        promptedThisLaunch = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The clipboard write happens first and unconditionally: without Accessibility the user
    /// still gets the snippet and can paste it themselves (`.copiedOnly`).
    static func paste(text: String, richRTFD: Data?, into app: NSRunningApplication?) -> Outcome {
        ClipboardBridge.write(text: text, richRTFD: richRTFD, imagePNG: nil)
        guard ensureTrusted() else { return .copiedOnly }
        if let app, !app.isActive { app.activate() }
        // Activation is asynchronous; a ⌘V posted before the target owns the key window lands
        // nowhere (or in Pastefix). 150 ms is the smallest delay that survived manual testing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { postCommandV() }
        return .pasted
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
