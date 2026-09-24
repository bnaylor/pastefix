import CoreGraphics
import Foundation
// Press ⌃⌥⌘1 but keep the modifiers held for `holdMs` after releasing the 1 key.
let holdMs = UInt32(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "500")!
let src = CGEventSource(stateID: .hidSystemState)
func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(20_000)
}
let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
post(59, down: true, flags: .maskControl)                       // control
post(58, down: true, flags: [.maskControl, .maskAlternate])     // option
post(55, down: true, flags: mods)                               // command
post(18, down: true, flags: mods)                               // 1
post(18, down: false, flags: mods)
usleep(holdMs * 1000)                                           // keep modifiers held
post(55, down: false, flags: [.maskControl, .maskAlternate])
post(58, down: false, flags: .maskControl)
post(59, down: false, flags: [])
print("posted; modifiers held \(holdMs) ms")
