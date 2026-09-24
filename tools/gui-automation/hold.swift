import CoreGraphics
import Foundation
// Usage: hold [ms]  — posts ⌃⌥⌘1 and keeps the three modifiers held for `ms` (default 500)
// after the 1 key is released, then posts the release sequence. `hold 0` is the recovery
// command when a previous run left modifiers stuck: it re-posts the chord and immediately
// releases everything.
guard let holdMs = CommandLine.arguments.count > 1 ? UInt32(CommandLine.arguments[1]) : 500 else {
    print("usage: hold [milliseconds]")
    exit(1)
}
let src = CGEventSource(stateID: .hidSystemState)
func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(20_000)
}

// Plan 9 lesson: modifiers left held combine with whatever is posted next — a stray ⌘V
// while ⌘ is still down pastes instead of typing "v", and a human's keystrokes pick up
// the held modifiers too.
//
// What this covers: the release sequence is posted unconditionally (a key-up for a
// modifier that is already up is a no-op), so it is safe to run more than once, and it
// runs on normal completion, from `atexit`, and from the SIGINT/SIGTERM/SIGHUP/SIGQUIT
// handlers (^C, kill, a closed terminal, ^\).
//
// What it does not cover: fatal signals (SIGSEGV, SIGABRT, SIGTRAP, SIGBUS, …) skip
// `atexit`, and SIGKILL cannot be caught, so a crash or `kill -9` inside the hold window
// leaves the modifiers held until someone taps ⌃, ⌥ and ⌘ once each (or runs `hold 0`).
// The handler is also not strictly async-signal-safe — CGEvent allocates — which is
// acceptable for a test tool that is almost always sleeping in `usleep` when a signal
// lands, not inside malloc.
func releaseModifiers() {
    post(55, down: false, flags: [.maskControl, .maskAlternate])  // command up
    post(58, down: false, flags: .maskControl)                    // option up
    post(59, down: false, flags: [])                              // control up
}
func handleSignal(_ sig: Int32) {
    releaseModifiers()
    exit(1) // runs atexit → releaseModifiers again; harmless
}
atexit(releaseModifiers)
signal(SIGINT, handleSignal)
signal(SIGTERM, handleSignal)
signal(SIGHUP, handleSignal)
signal(SIGQUIT, handleSignal)

let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
post(59, down: true, flags: .maskControl)                       // control
post(58, down: true, flags: [.maskControl, .maskAlternate])     // option
post(55, down: true, flags: mods)                               // command
post(18, down: true, flags: mods)                               // 1
post(18, down: false, flags: mods)
usleep(holdMs * 1000)                                           // keep modifiers held
releaseModifiers()
print("posted; modifiers held \(holdMs) ms")
