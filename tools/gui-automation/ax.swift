import Cocoa
import ApplicationServices
// Usage: ax <pid> [maxDepth]  — dumps role/title/value/frame for every AX element of the app's windows.
let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else { print("usage: ax <pid> [depth]"); exit(1) }
let maxDepth = args.count >= 3 ? Int(args[2]) ?? 12 : 12
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ v: AnyObject?) -> String {
    guard let v else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func frame(_ e: AXUIElement) -> String {
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(e, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = attr(e, kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
    return String(format: "x=%.0f y=%.0f w=%.0f h=%.0f (bottom=%.0f)", pos.x, pos.y, size.width, size.height, pos.y + size.height)
}
func dump(_ e: AXUIElement, _ depth: Int) {
    guard depth <= maxDepth else { return }
    let role = str(attr(e, kAXRoleAttribute)), sub = str(attr(e, kAXSubroleAttribute))
    let title = str(attr(e, kAXTitleAttribute)), desc = str(attr(e, kAXDescriptionAttribute))
    var value = str(attr(e, kAXValueAttribute)); let vlen = value.count; if value.count > 60 { value = String(value.prefix(60)) + "…(len \(vlen))" }
    let ph = str(attr(e, "AXPlaceholderValue" as String))
    let focused = str(attr(e, kAXFocusedAttribute))
    var line = String(repeating: "  ", count: depth) + role
    if !sub.isEmpty { line += "/" + sub }
    if !title.isEmpty { line += " title=\"\(title)\"" }
    if !desc.isEmpty { line += " desc=\"\(desc)\"" }
    if !value.isEmpty { line += " value=\"\(value.replacingOccurrences(of: "\n", with: "⏎"))\"" }
    if !ph.isEmpty { line += " placeholder=\"\(ph)\"" }
    if focused == "1" { line += " FOCUSED" }
    line += "  " + frame(e)
    print(line)
    if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { dump(k, depth + 1) } }
}
if let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
    for w in windows { dump(w, 0) }
} else { print("no windows (is Accessibility granted to the caller?)") }
