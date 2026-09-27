import AppKit
import Foundation

// Pasteboard fixtures for GUI passes, with an explicit pass lifecycle around the human's
// live clipboard:
//
//   pb begin [path]     snapshot every type of every item (0600 file, 0700 directory)
//   pb <fixture> …      text | concealed | concealed-late | legacy | tiff | png | rich
//   pb end [path]       restore, verify every saved type byte-for-byte, delete the save
//   pb discard [path]   drop the save without restoring
//   pb types | count    read-only
//
// Fixtures refuse unless a save exists, parses, and is younger than PFX_PB_MAX_AGE_HOURS
// (default 6): an old save means a previous pass was abandoned, and copying over the
// clipboard again would bury whatever the human has put there since.

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
// PFX_PB_NAME=<name> targets a private named pasteboard instead of the general one, so the
// begin/end round trip can be self-tested without touching the human's clipboard.
let pb = env["PFX_PB_NAME"].map { NSPasteboard(name: .init($0)) } ?? NSPasteboard.general
let fm = FileManager.default
let defaultStateDir = NSHomeDirectory() + "/.local/state/pfx-ui"

func marker(_ s: String) -> NSPasteboard.PasteboardType { .init(s) }
func fail(_ msg: String, _ code: Int32) -> Never { print(msg); exit(code) }
func arg(_ i: Int, _ what: String) -> String {
    guard args.count > i else { fail("usage: pb \(args[1]) \(what)", 1) }
    return args[i]
}

func defaultSavePath() -> String { env["PFX_PB_SAVE"] ?? (defaultStateDir + "/clipboard.json") }
func savePathArg() -> String { args.count > 2 ? args[2] : defaultSavePath() }
func maxAgeSeconds() -> TimeInterval { (env["PFX_PB_MAX_AGE_HOURS"].flatMap(Double.init) ?? 6) * 3600 }

// MARK: - Save file format (version 1)
//
// { "version": 1, "changeCount": N, "savedAt": "ISO-8601",
//   "missing": [{"item": i, "type": "<uti>"}, …],   types whose data(forType:) was nil
//   "items": [ [ ["<uti>", "<base64>"], … ], … ] }
//
// Items are ordered; each item's types are ordered as the source pasteboard listed them
// (the first type is the preferred representation), so restore re-declares them in the
// same order.

struct Save {
    var items: [[(uti: String, data: Data)]]
    var missing: [(item: Int, type: String)]
    var changeCount: Int
    var savedAt: String
    var typeCount: Int { items.reduce(0) { $0 + $1.count } }
}

func parseSave(_ raw: Data) -> Save? {
    guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          (obj["version"] as? Int) == 1,
          let rawItems = obj["items"] as? [[[String]]] else { return nil }
    var items: [[(uti: String, data: Data)]] = []
    for rawItem in rawItems {
        var types: [(uti: String, data: Data)] = []
        for pair in rawItem {
            guard pair.count == 2, let d = Data(base64Encoded: pair[1]) else { return nil }
            types.append((pair[0], d))
        }
        items.append(types)
    }
    let missing = (obj["missing"] as? [[String: Any]] ?? []).compactMap { m -> (item: Int, type: String)? in
        guard let i = m["item"] as? Int, let t = m["type"] as? String else { return nil }
        return (i, t)
    }
    return Save(items: items,
                missing: missing,
                changeCount: obj["changeCount"] as? Int ?? -1,
                savedAt: obj["savedAt"] as? String ?? "?")
}

func loadSave(at path: String) -> (save: Save?, error: String?) {
    guard let raw = fm.contents(atPath: path) else { return (nil, "no save file at \(path)") }
    guard let save = parseSave(raw) else { return (nil, "save file at \(path) does not parse (\(raw.count) bytes)") }
    return (save, nil)
}

// MARK: - Directory and file creation with tight modes

func ensurePrivateDirectory(_ dir: String) {
    var isDir: ObjCBool = false
    if !fm.fileExists(atPath: dir, isDirectory: &isDir) {
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch { fail("cannot create \(dir): \(error.localizedDescription)", 1) }
        return
    }
    guard isDir.boolValue else { fail("\(dir) exists and is not a directory", 1) }
    let mode = (try? fm.attributesOfItem(atPath: dir)[.posixPermissions] as? Int) ?? 0
    if mode & 0o077 != 0 {
        if dir == defaultStateDir {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir) // ours; tighten it
        } else {
            print("warning: \(dir) is mode \(String(mode, radix: 8)); the save is 0600 but its directory is not private")
        }
    }
}

/// Creates `path` with O_EXCL and mode 0600, so two `begin`s can never both win the race
/// and the bytes are never readable by anyone else, not even briefly.
func writeExclusive(_ data: Data, to path: String) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    fchmod(fd, 0o600) // umask-proof
    var ok = true
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n <= 0 { ok = false; return }
            off += n
        }
    }
    return ok
}

// MARK: - begin / end / discard

func begin(path: String) {
    if fm.fileExists(atPath: path) {
        fail("refusing: a save already exists at \(path) — a previous pass did not `end`; run `pb end` to restore it or `pb discard` to drop it", 2)
    }
    ensurePrivateDirectory((path as NSString).deletingLastPathComponent)

    var items: [[[String]]] = []
    var missing: [[String: Any]] = []
    for (i, item) in (pb.pasteboardItems ?? []).enumerated() {
        var pairs: [[String]] = []
        for type in item.types {
            if let data = item.data(forType: type) {
                pairs.append([type.rawValue, data.base64EncodedString()])
            } else {
                missing.append(["item": i, "type": type.rawValue])
            }
        }
        items.append(pairs)
    }
    let typeCount = items.reduce(0) { $0 + $1.count }
    let fmt = ISO8601DateFormatter()
    let doc: [String: Any] = [
        "version": 1,
        "changeCount": pb.changeCount,
        "savedAt": fmt.string(from: Date()),
        "missing": missing,
        "items": items,
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not encode the snapshot", 1)
    }
    guard writeExclusive(json, to: path) else {
        fail("refusing: could not create \(path) exclusively (\(String(cString: strerror(errno)))) — a save may already exist; see `pb end` / `pb discard`", 2)
    }
    print("begin: saved \(items.count) item(s), \(typeCount) type(s) to \(path) (changeCount \(pb.changeCount))")
    if !missing.isEmpty {
        print("warning: \(missing.count) type(s) returned no data and cannot be saved (promised/lazy data the provider has not materialised); `pb end` will report whether the pasteboard derives them again:")
        for m in missing { print("  - \(m["type"] ?? "?") (item \(m["item"] ?? "?"))") }
    }
}

func end(path: String) {
    let (loaded, err) = loadSave(at: path)
    guard let save = loaded else {
        fail("refusing: \(err ?? "unreadable save") — the pasteboard was NOT touched; nothing was restored and the save was kept", 3)
    }

    // Build every item before clearing, so a bad entry is a refusal, not a wipe.
    var restorable: [(index: Int, item: NSPasteboardItem)] = []
    var setFailures: [String] = []
    for (i, types) in save.items.enumerated() {
        let item = NSPasteboardItem()
        var declared = 0
        for t in types {
            if item.setData(t.data, forType: marker(t.uti)) { declared += 1 } else { setFailures.append("\(t.uti) (item \(i))") }
        }
        if declared > 0 { restorable.append((i, item)) }
    }

    pb.clearContents()
    let wrote = restorable.isEmpty ? true : pb.writeObjects(restorable.map(\.item))
    if !save.items.isEmpty, !wrote || restorable.isEmpty {
        fail("restore FAILED: the save held \(save.items.count) item(s) but none could be written; the pasteboard is now EMPTY; the save was kept at \(path) — retry `pb end` or restore by hand", 4)
    }

    // Verify: every saved type's bytes must read back identically.
    let live = pb.pasteboardItems ?? []
    var mismatches: [String] = []
    if live.count != restorable.count {
        mismatches.append("item count: wrote \(restorable.count), pasteboard has \(live.count)")
    }
    for (pos, entry) in restorable.enumerated() where pos < live.count {
        for t in save.items[entry.index] {
            let got = live[pos].data(forType: marker(t.uti))
            if got != t.data {
                mismatches.append("\(t.uti) (item \(entry.index)): saved \(t.data.count) B, read back \(got.map { "\($0.count) B" } ?? "nil")")
            }
        }
    }
    mismatches.append(contentsOf: setFailures.map { "\($0): setData refused" })
    if !mismatches.isEmpty {
        print("restore INCOMPLETE: \(save.items.count) item(s) written but \(mismatches.count) type(s) did not verify:")
        for m in mismatches { print("  - \(m)") }
        fail("the save was kept at \(path) — retry `pb end`, or tell the user exactly which types above were not restored", 4)
    }

    // Everything captured is back and verified; the save has no further use either way.
    do { try fm.removeItem(atPath: path) } catch {
        fail("restored and verified, but could not delete \(path): \(error.localizedDescription)", 1)
    }
    let summary = "restored \(save.items.count) item(s), \(save.typeCount) type(s); verified; save deleted"
    // Types that had no data at `begin`: AppKit derives some of them again from what was
    // restored (e.g. public.utf16-external-plain-text from the UTF-8 string); only the ones
    // the pasteboard no longer advertises at all are genuinely gone.
    let liveTypes = Set(live.flatMap { $0.types.map(\.rawValue) })
    let derived = save.missing.filter { liveTypes.contains($0.type) }
    let gone = save.missing.filter { !liveTypes.contains($0.type) }
    if gone.isEmpty {
        print(summary)
        if !derived.isEmpty {
            print("note: \(derived.count) type(s) had no data at `begin`; the pasteboard advertises them again (derived by AppKit from the restored types, bytes not verified):")
            for m in derived { print("  - \(m.type) (item \(m.item))") }
        }
    } else {
        print("\(summary) — BUT \(gone.count) type(s) could not be captured at `begin` and are NOT on the pasteboard now:")
        for m in gone { print("  - \(m.type) (item \(m.item))") }
        if !derived.isEmpty { print("(\(derived.count) other uncaptured type(s) were derived again by AppKit: \(derived.map(\.type).joined(separator: ", ")))") }
        exit(5)
    }
}

func discard(path: String) {
    let (loaded, err) = loadSave(at: path)
    guard fm.fileExists(atPath: path) else { fail(err ?? "no save file at \(path)", 1) }
    do { try fm.removeItem(atPath: path) } catch { fail("could not delete \(path): \(error.localizedDescription)", 1) }
    if let s = loaded {
        print("discarded save at \(path) without restoring: \(s.items.count) item(s), \(s.typeCount) type(s), saved \(s.savedAt)")
    } else {
        print("discarded unparseable save at \(path) without restoring")
    }
}

/// Fixtures may only run inside a pass: a save that exists, parses, and is fresh.
func requirePass() {
    let path = defaultSavePath()
    if env["PFX_PB_FORCE"] == "1" {
        print("PFX_PB_FORCE=1: skipping the pass check (no save required at \(path))")
        return
    }
    let (loaded, err) = loadSave(at: path)
    guard loaded != nil else {
        fail("refusing: \(err ?? "no save") — run `pb begin` first (or set PFX_PB_FORCE=1)", 2)
    }
    let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    let age = Date().timeIntervalSince(mtime)
    if age > maxAgeSeconds() {
        fail(String(format: "refusing: the save at %@ is %.1f h old (limit PFX_PB_MAX_AGE_HOURS=%.1f) — a previous pass was abandoned; run `pb end` to restore it or `pb discard` to drop it, then `pb begin`",
                    path, age / 3600, maxAgeSeconds() / 3600), 2)
    }
}

// MARK: - Fixtures

guard args.count > 1 else {
    fail("usage: pb begin|end|discard [path] | text|concealed|concealed-late|legacy|rich STR | tiff|png W H | types | count", 1)
}

switch args[1] {
case "begin": begin(path: savePathArg())
case "end": end(path: savePathArg())
case "discard": discard(path: savePathArg())
case "save", "restore":
    fail("`pb \(args[1])` was renamed: use `pb begin` before the pass and `pb end` after it (`pb discard` drops a save)", 1)
case "text":
    let s = arg(2, "STRING"); requirePass()
    pb.clearContents(); pb.setString(s, forType: .string)
case "concealed":
    let s = arg(2, "STRING"); requirePass()
    pb.clearContents()
    pb.setString(s, forType: .string)
    pb.setData(Data(), forType: marker("org.nspasteboard.ConcealedType"))
case "concealed-late":
    let s = arg(2, "STRING"); requirePass()
    // marker added AFTER the string, same change (the ordering the final review flagged)
    pb.clearContents()
    pb.setString(s, forType: .string)
    usleep(700_000)   // > one monitor tick between the string and the marker
    pb.setData(Data(), forType: marker("org.nspasteboard.ConcealedType"))
case "legacy":
    let s = arg(2, "STRING"); requirePass()
    pb.clearContents()
    pb.setString(s, forType: .string)
    pb.setData(Data(), forType: marker("de.petermaurer.TransientPasteboardType"))
case "tiff":
    guard let w = Int(arg(2, "W H")), let h = Int(arg(3, "W H")), w > 0, h > 0 else { fail("usage: pb tiff W H", 1) }
    requirePass()
    // An explicit bitmap rep, not NSImage + lockFocus: lockFocus picks up the display's backing
    // scale, so on Retina "tiff 8 6" came out 16x12 and a pixel-ceiling fixture's size depended
    // on which screen the helper ran on. This is exactly W x H pixels, uncompressed.
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32), let px = rep.bitmapData else { fail("could not allocate bitmap", 1) }
    for i in stride(from: 0, to: w * h * 4, by: 4) { px[i] = 48; px[i + 1] = 176; px[i + 2] = 199; px[i + 3] = 255 }
    guard let tiff = rep.tiffRepresentation else { fail("could not render TIFF", 1) }
    pb.clearContents(); pb.setData(tiff, forType: .tiff)
case "png":
    guard let w = Int(arg(2, "W H")), let h = Int(arg(3, "W H")), w > 0, h > 0 else { fail("usage: pb png W H", 1) }
    requirePass()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("could not allocate bitmap", 1) }
    for y in 0..<h { for x in 0..<w { rep.setColor(NSColor(red: CGFloat(x % 256)/255, green: CGFloat(y % 256)/255, blue: 0.5, alpha: 1), atX: x, y: y) } }
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode PNG", 1) }
    pb.clearContents(); pb.setData(png, forType: .png)
case "rich":
    let s = arg(2, "STRING"); requirePass()
    let a = NSMutableAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    guard let rtf = try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { fail("could not encode RTF", 1) }
    pb.clearContents(); pb.setData(rtf, forType: .rtf); pb.setString(s, forType: .string)
case "types":
    print((pb.types ?? []).map(\.rawValue).joined(separator: "\n"))
case "count":
    print(pb.changeCount)
default:
    fail("unknown subcommand \(args[1]); see the usage line (`pb`)", 1)
}
