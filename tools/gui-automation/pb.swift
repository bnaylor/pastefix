import AppKit
let args = CommandLine.arguments
let pb = NSPasteboard.general
func marker(_ s: String) -> NSPasteboard.PasteboardType { .init(s) }
switch args[1] {
case "text":
    pb.clearContents(); pb.setString(args[2], forType: .string)
case "concealed":
    pb.clearContents()
    pb.setString(args[2], forType: .string)
    pb.setData(Data(), forType: marker("org.nspasteboard.ConcealedType"))
case "concealed-late":
    // marker added AFTER the string, same change (the ordering the final review flagged)
    pb.clearContents()
    pb.setString(args[2], forType: .string)
    usleep(700_000)   // > one monitor tick between the string and the marker
    pb.setData(Data(), forType: marker("org.nspasteboard.ConcealedType"))
case "legacy":
    pb.clearContents()
    pb.setString(args[2], forType: .string)
    pb.setData(Data(), forType: marker("de.petermaurer.TransientPasteboardType"))
case "tiff":
    let w = Int(args[2])!, h = Int(args[3])!
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); img.unlockFocus()
    pb.clearContents(); pb.setData(img.tiffRepresentation!, forType: .tiff)
case "png":
    let w = Int(args[2])!, h = Int(args[3])!
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<h { for x in 0..<w { rep.setColor(NSColor(red: CGFloat(x % 256)/255, green: CGFloat(y % 256)/255, blue: 0.5, alpha: 1), atX: x, y: y) } }
    pb.clearContents(); pb.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
case "rich":
    let a = NSMutableAttributedString(string: args[2], attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    let rtf = try! a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    pb.clearContents(); pb.setData(rtf, forType: .rtf); pb.setString(args[2], forType: .string)
case "types":
    print((pb.types ?? []).map(\.rawValue).joined(separator: "\n"))
case "count":
    print(pb.changeCount)
default: print("?")
}
