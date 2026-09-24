import AppKit
import Foundation

let args = CommandLine.arguments
let pb = NSPasteboard.general
func marker(_ s: String) -> NSPasteboard.PasteboardType { .init(s) }

func defaultSavePath() -> String {
    ProcessInfo.processInfo.environment["PFX_PB_SAVE"]
        ?? (NSHomeDirectory() + "/.local/state/pfx-ui/clipboard.json")
}

// Every destructive subcommand refuses to run unless a save file already exists, so a pass
// can never clobber whatever was on the clipboard before it started without a way back.
func requireSave() {
    if ProcessInfo.processInfo.environment["PFX_PB_FORCE"] == "1" { return }
    let path = defaultSavePath()
    if !FileManager.default.fileExists(atPath: path) {
        print("refusing: no clipboard save at \(path) — run 'pb save \(path)' first (or set PFX_PB_FORCE=1)")
        exit(2)
    }
}

// Saves every type of every pasteboard item (not just text), so restore is a full round trip.
func savePasteboard(to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    var out: [[String: [String: String]]] = []
    for item in pb.pasteboardItems ?? [] {
        var types: [String: String] = [:]
        for type in item.types {
            guard let data = item.data(forType: type) else { continue }
            types[type.rawValue] = data.base64EncodedString()
        }
        out.append(["types": types])
    }
    let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    try! json.write(to: URL(fileURLWithPath: path))
    print("saved \(out.count) item(s) to \(path)")
}

func restorePasteboard(from path: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("no save file at \(path)")
        exit(1)
    }
    let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: [String: String]]] ?? []
    pb.clearContents()
    var items: [NSPasteboardItem] = []
    for entry in raw {
        let item = NSPasteboardItem()
        for (uti, b64) in entry["types"] ?? [:] {
            guard let d = Data(base64Encoded: b64) else { continue }
            item.setData(d, forType: marker(uti))
        }
        items.append(item)
    }
    pb.writeObjects(items)
    print("restored \(items.count) item(s) from \(path)")
}

switch args[1] {
case "save":
    savePasteboard(to: args.count > 2 ? args[2] : defaultSavePath())
case "restore":
    restorePasteboard(from: args.count > 2 ? args[2] : defaultSavePath())
case "text":
    requireSave()
    pb.clearContents(); pb.setString(args[2], forType: .string)
case "concealed":
    requireSave()
    pb.clearContents()
    pb.setString(args[2], forType: .string)
    pb.setData(Data(), forType: marker("org.nspasteboard.ConcealedType"))
case "concealed-late":
    requireSave()
    // marker added AFTER the string, same change (the ordering the final review flagged)
    pb.clearContents()
    pb.setString(args[2], forType: .string)
    usleep(700_000)   // > one monitor tick between the string and the marker
    pb.setData(Data(), forType: marker("org.nspasteboard.ConcealedType"))
case "legacy":
    requireSave()
    pb.clearContents()
    pb.setString(args[2], forType: .string)
    pb.setData(Data(), forType: marker("de.petermaurer.TransientPasteboardType"))
case "tiff":
    requireSave()
    let w = Int(args[2])!, h = Int(args[3])!
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); img.unlockFocus()
    pb.clearContents(); pb.setData(img.tiffRepresentation!, forType: .tiff)
case "png":
    requireSave()
    let w = Int(args[2])!, h = Int(args[3])!
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<h { for x in 0..<w { rep.setColor(NSColor(red: CGFloat(x % 256)/255, green: CGFloat(y % 256)/255, blue: 0.5, alpha: 1), atX: x, y: y) } }
    pb.clearContents(); pb.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
case "rich":
    requireSave()
    let a = NSMutableAttributedString(string: args[2], attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    let rtf = try! a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    pb.clearContents(); pb.setData(rtf, forType: .rtf); pb.setString(args[2], forType: .string)
case "types":
    print((pb.types ?? []).map(\.rawValue).joined(separator: "\n"))
case "count":
    print(pb.changeCount)
default: print("?")
}
