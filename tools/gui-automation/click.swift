import Cocoa
import ApplicationServices
import CoreGraphics
import Foundation

// Usage: click <pid> <x> <y>  — posts a left click at a screen point, but only after
// reading the target pid's AX windows:
//   exit 3, no event: the windows attribute could not be read at all (no Accessibility
//           grant for the host app running this shell, or no such pid);
//   exit 2, no event: the point is outside every window of pid (a stale coordinate);
//   exit 0: mouse-moved, down, up posted at the point.
// The pid scope is not a scale validator (a doubled coordinate can still land inside the
// same window) and does no z-order check (a foreign window over the target still takes
// the click).
let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[1]), let x = Double(args[2]), let y = Double(args[3]) else {
    print("usage: click <pid> <x> <y>")
    exit(1)
}
let p = CGPoint(x: x, y: y)

let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func windowFrame(_ e: AXUIElement) -> CGRect {
    var pos = CGPoint.zero, size = CGSize.zero
    if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }
    if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
    return CGRect(origin: pos, size: size)
}

var rawWindows: AnyObject?
let axErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
guard axErr == .success, let windows = rawWindows as? [AXUIElement] else {
    print("refusing: could not read windows for pid \(pid) (Accessibility grant for this terminal? wrong pid?) — AXError \(axErr.rawValue)")
    exit(3)
}
let frames = windows.map(windowFrame)
guard frames.contains(where: { $0.contains(p) }) else {
    let list = frames.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" }.joined(separator: " ")
    print("refusing: (\(x), \(y)) is outside every window of pid \(pid) — \(frames.count) window(s): \(list)")
    exit(2)
}

CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(80_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(60_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
