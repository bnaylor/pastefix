import AppKit
import ApplicationServices

/// Puts a snippet on the clipboard and pastes it into another app by posting ⌘V. Accessibility
/// permission is required to post the key event; Pastefix uses it for nothing else — no event
/// tap, no key observation.
@MainActor
enum SnippetPaster {
    enum Outcome: Equatable { case pasted, copiedOnly }
    private static var promptedThisLaunch = false

    /// How long the target gets to come forward before we look for it again.
    private static let activationSettle: TimeInterval = 0.15
    /// How long we will wait for the user to release the hotkey's modifiers (see `postWhenReady`).
    private static let modifierWait: TimeInterval = 1.0
    private static let modifierPoll: TimeInterval = 0.02

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt at most once per launch. Returns the current trust state.
    ///
    /// `AXIsProcessTrusted` re-reads TCC on every call — the relaunch requirement people remember
    /// applies to event *taps*, and this app holds none — so a mid-session grant is picked up
    /// without restarting. The prompt itself returns the state from *before* the user answers, so
    /// the paste that triggered it always degrades to `.copiedOnly`.
    @discardableResult
    static func ensureTrusted() -> Bool {
        if isTrusted { return true }
        guard !promptedThisLaunch else { return false }
        promptedThisLaunch = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Writes the snippet to the clipboard, brings `app` forward, and schedules a ⌘V into it.
    ///
    /// **Call this before hiding any Pastefix window.** The activation request is made
    /// synchronously here, while Pastefix is still the active app, so it can hand its activation
    /// right to the target via the macOS 14 cooperative form. Ordering it the other way — hide,
    /// then activate — makes a background agent ask for an activation it no longer owns, which is
    /// exactly the request macOS is most likely to refuse or reorder.
    ///
    /// The clipboard write happens first and unconditionally: whenever anything downstream fails,
    /// the user still has the snippet and can paste it themselves (`.copiedOnly`).
    ///
    /// `.pasted` means activation succeeded and a post is scheduled — the post itself is still
    /// conditional on the frontmost re-check in `postWhenReady`, so it remains a prediction.
    static func paste(text: String, richRTFD: Data?, into app: NSRunningApplication?) -> Outcome {
        ClipboardBridge.write(text: text, richRTFD: richRTFD, imagePNG: nil)
        guard ensureTrusted() else { return .copiedOnly }
        // No target, a dead target, or ourselves: never post. Pastefix as the target means the
        // hotkey fired while our own panel was key, and a ⌘V would land in the editor or a search
        // field — a silent edit to a session the user may then Save.
        guard let app, !app.isTerminated,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else { return .copiedOnly }
        if !app.isActive {
            guard app.activate(from: .current, options: []) else { return .copiedOnly }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + activationSettle) {
            postWhenReady(targetPID: app.processIdentifier, deadline: Date().addingTimeInterval(modifierWait))
        }
        return .pasted
    }

    /// Posts ⌘V only once the user has let go of everything and the target really is frontmost.
    ///
    /// `onKeyUp` fires on key-*up* of the shortcut's character key, so a ⌥⌘1 hotkey still has ⌥⌘
    /// physically down at this point, and `.cghidEventTap` re-derives live hardware modifiers
    /// below the window server: our ⌘V would arrive as ⌥⌘V, which in Finder is *Move Items Here*.
    /// Setting `flags` on the event does not clear that hardware state, so we wait for it instead.
    /// On timeout we deliberately post nothing — the clipboard already holds the snippet.
    private static func postWhenReady(targetPID: pid_t, deadline: Date) {
        guard NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + modifierPoll) {
                postWhenReady(targetPID: targetPID, deadline: deadline)
            }
            return
        }
        // Activation is asynchronous and can be refused after the fact; without this the ⌘V types
        // the clipboard into whatever happens to be frontmost now.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
        postCommandV()
    }

    private static func postCommandV() {
        // `.privateState`, not `.combinedSessionState`: the combined source merges live hardware
        // modifiers into the event we are building.
        let source = CGEventSource(stateID: .privateState)
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
