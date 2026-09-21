import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts a snippet on the clipboard and pastes it into another app by posting ⌘V. Accessibility
/// permission is required to post the key event; Pastefix uses it for nothing else — no event
/// tap, no key observation.
@MainActor
enum SnippetPaster {
    enum Outcome: Equatable { case pasted, copiedOnly }
    private static var promptedThisLaunch = false

    /// How long `postWhenReady` will wait for the target to come forward and the user to let go
    /// of the hotkey's modifiers, and how often it re-checks.
    private static let readyWait: TimeInterval = 1.0
    private static let readyPoll: TimeInterval = 0.02

    /// The modifiers that would re-interpret our ⌘V into a different chord, and so the only ones
    /// worth waiting on. Deliberately NOT `.deviceIndependentFlagsMask`: that includes
    /// `.capsLock`, which latches — with Caps Lock on it is reported continuously with no key
    /// held, so waiting for it to clear means never pasting at all. `.function`, `.numericPad`
    /// and `.help` are excluded for the same reason they are harmless: they do not affect ⌘V.
    private static let blockingModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Identifies the newest paste request. The clipboard is one slot, so two pastes inside the
    /// wait window cannot both be right: the newest wins and older chains stop without posting.
    private static var pendingGeneration = 0

    /// Supersedes every paste chain currently in flight.
    ///
    /// Called by `ClipboardBridge` on every write to the general pasteboard, because a chain's
    /// whole premise is "the clipboard holds *my* text". Save, copy-back and the ⌘K palette all
    /// write through that one door, so a chain that is still waiting when any of them fires would
    /// otherwise go on to post whatever they left behind into its target.
    static func invalidatePending() { pendingGeneration &+= 1 }

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
        return promptForTrust()
    }

    /// Always prompts — for the explicit Settings button, where the user asked for it.
    ///
    /// `ensureTrusted`'s once-per-launch rule is right for the *implicit* prompt inside `paste`
    /// and wrong here: a user who dismissed the first prompt by accident and then pressed
    /// "Request…" would get a button that does literally nothing.
    @discardableResult
    static func requestTrust() -> Bool {
        if isTrusted { return true }
        promptedThisLaunch = true
        return promptForTrust()
    }

    private static func promptForTrust() -> Bool {
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
    /// `onGaveUp` is how a caller hears about that prediction failing: it runs once, on the main
    /// actor, if the chain ends without posting — its deadline expires, or the post itself cannot
    /// be built. A `.copiedOnly` return and an `onGaveUp` call are mutually exclusive, so a caller
    /// can treat them as the same signal.
    static func paste(text: String,
                      richRTFD: Data?,
                      into app: NSRunningApplication?,
                      onGaveUp: (() -> Void)? = nil) -> Outcome {
        // The write itself invalidates every older chain (`ClipboardBridge` calls
        // `invalidatePending`), which is what makes the ordering here load-bearing: capture the
        // generation *after* the write, so this chain is the current one and the chains it
        // superseded stay quiet. That also covers the early returns below — a request refused
        // after this point still overwrote the clipboard.
        ClipboardBridge.write(text: text, richRTFD: richRTFD, imagePNG: nil)
        let generation = pendingGeneration
        guard ensureTrusted() else { return .copiedOnly }
        // No resolvable "v" on this layout (an input source with no `uchr` data) means there is
        // no chord we are willing to post; the snippet is on the clipboard either way.
        guard keyCodeForV() != nil else { return .copiedOnly }
        // No target, a dead target, or ourselves: never post. Pastefix as the target means the
        // hotkey fired while our own panel was key, and a ⌘V would land in the editor or a search
        // field — a silent edit to a session the user may then Save.
        guard let app, !app.isTerminated,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else { return .copiedOnly }
        if !app.isActive {
            guard app.activate(from: .current, options: []) else { return .copiedOnly }
        }
        let target = app.processIdentifier
        let deadline = Date().addingTimeInterval(readyWait)
        DispatchQueue.main.asyncAfter(deadline: .now() + readyPoll) {
            postWhenReady(targetPID: target, generation: generation, deadline: deadline, onGaveUp: onGaveUp)
        }
        return .pasted
    }

    /// Posts ⌘V once — and only once — both conditions hold: no blocking modifier is down, and the
    /// target really is the frontmost app. Both share one deadline, and a timeout posts nothing;
    /// the clipboard already holds the snippet, so the user can ⌘V themselves.
    ///
    /// The modifier half: `onKeyUp` fires on key-*up* of the shortcut's character key, so a ⌥⌘1
    /// hotkey still has ⌥⌘ physically down at this point, and `.cghidEventTap` re-derives live
    /// hardware modifiers below the window server — our ⌘V would arrive as ⌥⌘V, which in Finder
    /// is *Move Items Here*. Setting `flags` on the event does not clear that hardware state.
    ///
    /// The frontmost half: `activate` only *requests* activation, and a busy target, App Nap or a
    /// Space switch can take longer than one tick to land. Retrying rather than bailing on the
    /// first mismatch is strictly safer, not laxer — a target that never comes forward (including
    /// because the user switched to a third app) still ends in posting nothing.
    ///
    /// Expiring is a real outcome, not a non-event: the snippet is on the clipboard and the user
    /// is waiting for a paste that will never arrive, so the deadline path calls `onGaveUp`. The
    /// generation check stays ahead of it — a superseded chain has been replaced, not failed, and
    /// must stay quiet.
    private static func postWhenReady(targetPID: pid_t,
                                      generation: Int,
                                      deadline: Date,
                                      onGaveUp: (() -> Void)?) {
        guard generation == pendingGeneration else { return }
        // `NSApp.keyWindow == nil` is not redundant with the frontmost check. The panel is an
        // `.nonactivatingPanel`, which is precisely the style mask that lets it hold *key* focus
        // while `NSApp.isActive` is false and another app is genuinely frontmost — summon, click
        // another app, click back on the panel. Posting then plausibly routes ⌘V to our own
        // editor or search field. Never post while any Pastefix window is key; folding it into
        // the readiness test rather than the entry guard means a panel that closes during the
        // wait still lets the paste through.
        let ready = NSApp.keyWindow == nil
            && NSEvent.modifierFlags.intersection(blockingModifiers).isEmpty
            && focusedPID() == targetPID
        guard ready else {
            guard Date() < deadline else { onGaveUp?(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + readyPoll) {
                postWhenReady(targetPID: targetPID, generation: generation, deadline: deadline, onGaveUp: onGaveUp)
            }
            return
        }
        // Key resolution can still fail here (the input source changed during the wait), and a
        // CGEvent can fail to allocate. Both mean nothing was posted, which for the caller is the
        // same outcome as running out of deadline.
        if !postCommandV() { onGaveUp?() }
    }

    /// The pid of the application that currently has keyboard focus, read through Accessibility
    /// with `NSWorkspace` as the fallback.
    ///
    /// `NSWorkspace.shared.frontmostApplication` is an asynchronously updated cache — the same
    /// property `FrontmostAppTracker` documents as unreliable — so under a main-thread stall it
    /// can still name the previous app at the moment we post. The system-wide AX element answers
    /// synchronously from the window server's own focus state, and we already hold Accessibility
    /// for this feature, so this is strictly the better question to ask.
    ///
    /// Be honest about what it buys: this *narrows* the window between the check and the post, it
    /// cannot close it. Nothing can — focus can change in the microseconds after any check. The
    /// fallback is deliberate too: an AX call that fails should not silently turn every paste into
    /// a copy, so a failure leaves us exactly where this code was before.
    private static func focusedPID() -> pid_t? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWideElement,
                                                   kAXFocusedApplicationAttribute as CFString,
                                                   &value)
        if status == .success, let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            // Forced, but guarded: `CFGetTypeID` above has already established the type, and the
            // attribute is documented to be an AXUIElement.
            let element = raw as! AXUIElement
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Kept rather than created per call, because the messaging timeout is a property of the
    /// element. The readiness loop runs on the main thread every 20 ms, so cap what one AX call
    /// can cost: the focused-application query is answered by the accessibility runtime rather
    /// than by the target app, but the default timeout is measured in seconds and a hung app must
    /// never be able to freeze our main thread. A timeout reads as a failure and falls back.
    private static let systemWideElement: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    /// Returns false when nothing was posted.
    private static func postCommandV() -> Bool {
        // `.privateState`, not `.combinedSessionState`: the combined source merges live hardware
        // modifiers into the event we are building.
        let source = CGEventSource(stateID: .privateState)
        guard let key = keyCodeForV(),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// The virtual key that produces "v" on the *current* keyboard layout.
    ///
    /// A `.cghidEventTap` post lands below the window server, which then derives the character
    /// from the active layout — so a hardcoded 9 is "v" only on ANSI-derived layouts. On plain
    /// Dvorak key 9 is "k", and ⌘K clears the scrollback in Terminal and inserts a link in Mail:
    /// the same failure family as the Caps Lock and held-modifier bugs, a posted chord that means
    /// something other than "paste". Resolved by translating each key code through the layout's
    /// `uchr` data — in the Command state the event is actually posted in — and taking the first
    /// that yields "v".
    ///
    /// Nil means "we don't know", and the caller must then post nothing: everywhere else this file
    /// prefers copy-only to a guess, and caching a guess would be worse still — one transient
    /// `TISCopyCurrentKeyboardLayoutInputSource` failure would pin ANSI 9 until the next layout
    /// change, which on Dvorak is ⌘K. Only a successful resolution is cached.
    private static func keyCodeForV() -> CGKeyCode? {
        installLayoutObserverIfNeeded()
        if let cached = cachedVKeyCode { return cached }
        guard let resolved = resolveKeyCodeForV() else { return nil }
        cachedVKeyCode = resolved
        return resolved
    }

    /// Invalidated on `kTISNotifySelectedKeyboardInputSourceChanged`, which is a distributed
    /// notification — the observer is installed once, lazily, alongside the first lookup.
    private static var cachedVKeyCode: CGKeyCode?
    private static var layoutObserverInstalled = false

    private static func installLayoutObserverIfNeeded() {
        guard !layoutObserverInstalled else { return }
        layoutObserverInstalled = true
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { cachedVKeyCode = nil }
        }
    }

    /// Three tiers, in order:
    ///
    /// 1. Scan the layout's **command** key map, because that is the state the posted event is
    ///    really in. "Dvorak — QWERTY ⌘" reverts to QWERTY while ⌘ is held — that is the whole
    ///    reason people choose it — and it encodes that as a separate command-state map. Asking
    ///    the unmodified question there finds Dvorak's "v" at key 47, which the window server
    ///    then re-reads through the command map as "." : we would post ⌘. (Cancel).
    /// 2. Scan unmodified, for a layout that carries no command map at all (most of them; the
    ///    two scans agree there, so this tier only matters if tier 1 somehow finds nothing).
    ///
    /// There is no third tier. An input source with no `uchr` data at all (CJK input methods)
    /// returns nil and the paste degrades to copy-only, rather than posting an ANSI 9 that the
    /// window server may read as some other letter entirely.
    private static func resolveKeyCodeForV() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        // `modifierKeyState` is the *high byte* of the classic modifiers field, so Command is
        // `(cmdKey >> 8) & 0xFF`, which is 1 — not `cmdKey` itself.
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return scanForV(layoutData: layoutData, modifierKeyState: commandState)
            ?? scanForV(layoutData: layoutData, modifierKeyState: 0)
    }

    private static func scanForV(layoutData: Data, modifierKeyState: UInt32) -> CGKeyCode? {
        layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            // 0…50 covers the alphanumeric block; beyond it are modifiers, the function row and
            // the keypad, none of which can be the layout's "v".
            for code in CGKeyCode(0)...CGKeyCode(50) {
                // The *mask*, not the bit (which is 0, i.e. dead keys still on), and a fresh
                // state per key so a dead key earlier in the scan cannot colour a later one.
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(layout,
                                            UInt16(code),
                                            UInt16(kUCKeyActionDown),
                                            modifierKeyState,
                                            UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState,
                                            chars.count,
                                            &length,
                                            &chars)
                guard status == noErr, length == 1 else { continue }
                if String(utf16CodeUnits: chars, count: length) == "v" { return code }
            }
            return nil
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
