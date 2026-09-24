import Cocoa
import ApplicationServices
import CoreGraphics
import Foundation

// Usage: click <pid> <x> <y>  — refuses (exit 2, no events posted) if the point falls
// outside every window of pid, so a stale coordinate can't click into whatever else is
// on screen.
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

let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
let inside = windows.contains { windowFrame($0).contains(p) }
guard inside else {
    print("refusing: (\(x), \(y)) is outside every window of pid \(pid)")
    exit(2)
}

CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(80_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(60_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
