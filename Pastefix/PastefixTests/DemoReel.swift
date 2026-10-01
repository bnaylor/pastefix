import Testing
import AppKit
import SwiftUI
import PastefixCore
import PastefixAppCore
@testable import Pastefix

/// Renders README demo frames from the real panel (docs/media). Opt-in: runs only when
/// `PFX_DEMO_OUT` names an output folder (`TEST_RUNNER_PFX_DEMO_OUT=… scripts/test-app.sh …`), so
/// normal test runs skip it. Planted content only: no real clipboard or history.
@MainActor
@Suite("demo reel", .enabled(if: ProcessInfo.processInfo.environment["PFX_DEMO_OUT"] != nil))
struct DemoReel {
    nonisolated static var out: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["PFX_DEMO_OUT"] ?? "/tmp") }

    /// A dark terminal-ish screenshot with a token in it, drawn with AppKit text.
    static func terminalShot(width: Int = 1200, height: Int = 760) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1).setFill(); NSRect(x: 0, y: height - 44, width: width, height: 44).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: 20 + i * 26, y: height - 30, width: 15, height: 15)).fill()
        }
        let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
        let lines: [(String, NSColor)] = [
            ("$ ./deploy.sh --env prod", .white),
            ("Building release 4.2.1 ...", NSColor(white: 0.7, alpha: 1)),
            ("  ✓ compiled 312 files", NSColor.systemGreen),
            ("  ✓ uploaded artefacts", NSColor.systemGreen),
            ("export API_TOKEN=pfx_live_7Hq2LmN9xR4tVw8Kc3Za", NSColor.systemYellow),
            ("Deploying to https://api.example.invalid", NSColor(white: 0.7, alpha: 1)),
            ("  ✗ health check failed: 502 Bad Gateway", NSColor.systemRed),
            ("$ ", .white),
        ]
        for (i, (text, color)) in lines.enumerated() {
            (text as NSString).draw(at: NSPoint(x: 36, y: height - 110 - i * 72), withAttributes: [.font: font, .foregroundColor: color])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func window(_ f: ModelFixture, appearance: NSAppearance.Name?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        if let appearance { w.appearance = NSAppearance(named: appearance) }
        w.contentView = NSHostingView(rootView: PanelView(model: f.model, settings: f.settings))
        w.makeKeyAndOrderFront(nil)
        return w
    }

    static func snapshot(_ w: NSWindow, _ name: String) throws {
        let view = try #require(w.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try data.write(to: out.appendingPathComponent(name + ".png"))
    }

    /// The real composited window — chrome, shadow, every control — via the window server. A process
    /// may capture its own windows without Screen Recording permission.
    static func capture(_ w: NSWindow, _ name: String, into dir: URL = DemoReel.out, shadow: Bool = true) throws {
        let options: CGWindowImageOption = shadow ? [.bestResolution] : [.bestResolution, .boundsIgnoreFraming]
        // Marked unavailable in the macOS 15 SDK (ScreenCaptureKit replaces it, behind a permission
        // prompt); still present at runtime, and the one way to grab our own window as composited.
        typealias Fn = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        let handle = try #require(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW))
        let sym = try #require(dlsym(handle, "CGWindowListCreateImage"))
        let create = unsafeBitCast(sym, to: Fn.self)
        let image = try #require(create(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), options)?.takeRetainedValue())
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private func key(_ w: NSWindow, _ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        _ = w.performKeyEquivalent(with: e)
    }

    // MARK: reel

    /// Collects numbered frames and their display durations into `out/frames` + `frames.txt`
    /// (an ffmpeg concat list).
    final class Reel {
        let dir: URL
        var n = 0
        var list = ""
        init(_ name: String) throws {
            dir = DemoReel.out.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        @MainActor func frame(_ w: NSWindow, _ label: String, hold seconds: Double) throws {
            n += 1
            let name = String(format: "%03d-%@", n, label)
            try DemoReel.capture(w, name, into: dir)
            list += "file '\(name).png'\nduration \(seconds)\n"
            try list.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        }
    }

    static func typeText(_ w: NSWindow, _ text: String) async {
        for ch in text {
            let s = String(ch)
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                     isARepeat: false, keyCode: 0)!
            NSApplication.shared.sendEvent(e)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
    static func pressReturn(_ w: NSWindow) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                 isARepeat: false, keyCode: 36)!
        NSApplication.shared.sendEvent(e)
    }

    // MARK: content

    /// A dark card with a name, an email and a phone number: something you'd blur before sharing.
    static func profileShot(width: Int = 1200, height: Int = 700) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(srgbRed: 0.19, green: 0.21, blue: 0.26, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: width - 160, height: height - 160), xRadius: 28, yRadius: 28).fill()
        NSColor.systemTeal.setFill(); NSBezierPath(ovalIn: NSRect(x: 140, y: height - 330, width: 170, height: 170)).fill()
        ("AL" as NSString).draw(at: NSPoint(x: 178, y: height - 285), withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white])
        let big = NSFont.systemFont(ofSize: 48, weight: .semibold), mid = NSFont.systemFont(ofSize: 32)
        ("Ada Lovelace" as NSString).draw(at: NSPoint(x: 360, y: height - 240), withAttributes: [.font: big, .foregroundColor: NSColor.white])
        ("Analytical Engines Ltd." as NSString).draw(at: NSPoint(x: 360, y: height - 300), withAttributes: [.font: mid, .foregroundColor: NSColor(white: 0.7, alpha: 1)])
        ("ada@analytical.example" as NSString).draw(at: NSPoint(x: 140, y: height - 450), withAttributes: [.font: mid, .foregroundColor: NSColor.systemBlue])
        ("+44 20 7946 0958" as NSString).draw(at: NSPoint(x: 140, y: height - 510), withAttributes: [.font: mid, .foregroundColor: NSColor(white: 0.85, alpha: 1)])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: the tour

    /// The README tour: nine scenes, frames into `out/tour`, `frames.txt` for ffmpeg and
    /// `captions.txt` for the assembly step (`scripts/make-demo-gif.sh`).
    @Test func tour() async throws {
        let reel = try Reel("tour")
        var captions = ""
        func caption(_ text: String) { captions += "\(reel.n + 1)\t\(text)\n" }
        func fresh(_ snapshot: ClipboardSnapshot, setup: (ModelFixture) throws -> Void = { _ in }) async throws -> (ModelFixture, NSWindow) {
            let f = try ModelFixture()
            try setup(f)
            f.model.beginSession(from: snapshot)
            let w = Self.window(f, appearance: .darkAqua)
            try await Task.sleep(for: .milliseconds(600))
            return (f, w)
        }
        func settle(_ f: ModelFixture) async throws {
            #expect(await f.eventually { f.model.pendingMarks.isEmpty && !f.model.isApplying })
            try await Task.sleep(for: .milliseconds(500))
        }
        func palette(_ w: NSWindow, _ query: String, _ name: String) async throws {
            key(w, "k", 40, [.command])
            try await Task.sleep(for: .milliseconds(350))
            await Self.typeText(w, query)
            try await Task.sleep(for: .milliseconds(350))
            try reel.frame(w, name, hold: 1.1)
            Self.pressReturn(w)
        }
        /// A region transform shown as the selection, then the result: applied, undone (which brings
        /// the region back on screen), captured, redone.
        func regionScene(_ f: ModelFixture, _ w: NSWindow, _ t: any Transformer, _ region: ImageRegion, _ name: String) async throws {
            let revision = try #require(f.model.document?.detectionRevision)
            f.model.apply(t, scope: .image(region, revision: revision))
            try await settle(f)
            let um = try #require(f.model.undoManager)
            um.undo(); try await settle(f)
            try reel.frame(w, name + "-selected", hold: 1.3)
            um.redo(); try await settle(f)
            try reel.frame(w, name + "-done", hold: 1.9)
        }

        // 1. Markup
        do {
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: Self.terminalShot())) {
                $0.model.markupTool = .arrow
            }
            defer { w.orderOut(nil); f.finish() }
            caption("Mark up a screenshot: boxes, arrows, labels")
            try reel.frame(w, "markup-start", hold: 1.0)
            key(w, "a", 0, [.command, .shift]); try await Task.sleep(for: .milliseconds(300))
            f.model.enqueueMark(ImageMark(tool: .box, color: .red, points: [ImagePoint(x: 24, y: 362), ImagePoint(x: 784, y: 412)]))
            try await settle(f); try reel.frame(w, "markup-box", hold: 0.7)
            f.model.enqueueMark(ImageMark(tool: .arrow, color: .red, points: [ImagePoint(x: 1010, y: 610), ImagePoint(x: 800, y: 420)]))
            try await settle(f); try reel.frame(w, "markup-arrow", hold: 0.7)
            f.model.enqueueMark(ImageMark(tool: .text, color: .yellow, points: [ImagePoint(x: 790, y: 630)], text: "rotate this key!", textSize: .l))
            try await settle(f); try reel.frame(w, "markup-label", hold: 2.2)
        }
        // 2. Redact
        do {
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: Self.terminalShot()))
            defer { w.orderOut(nil); f.finish() }
            caption("Redact part of an image for good")
            try await regionScene(f, w, RedactSelection(), ImageRegion(x: 300, y: 362, width: 484, height: 50), "redact")
        }
        // 3. Blur
        do {
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: Self.profileShot()))
            defer { w.orderOut(nil); f.finish() }
            caption("Blur what you'd rather not share")
            try await regionScene(f, w, BlurSelection(), ImageRegion(x: 120, y: 405, width: 460, height: 130), "blur")
        }
        // 4. Crop
        do {
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: Self.terminalShot()))
            defer { w.orderOut(nil); f.finish() }
            caption("Crop to just the part that matters")
            try await regionScene(f, w, CropToSelection(), ImageRegion(x: 0, y: 330, width: 900, height: 280), "crop")
        }
        // 5. JSON
        do {
            let json = #"{"user":{"id":4182,"name":"Ada","roles":["admin","dev"]},"active":true,"tags":["beta","ops"]}"#
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: json, richRTFD: nil))
            defer { w.orderOut(nil); f.finish() }
            caption("⌘K: find a transform and apply it")
            try reel.frame(w, "json", hold: 1.0)
            try await palette(w, "pretty", "json-palette")
            #expect(await f.eventually { f.model.document?.working.contains("\n") == true })
            try await Task.sleep(for: .milliseconds(400))
            try reel.frame(w, "json-done", hold: 1.8)
        }
        // 6. Secrets
        do {
            let env = "DATABASE_URL=postgres://app@db.internal:5432/app\nAWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\nAWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\nLOG_LEVEL=info\n"
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: env, richRTFD: nil))
            defer { w.orderOut(nil); f.finish() }
            caption("Spot secrets before you paste them")
            try await Task.sleep(for: .milliseconds(600))
            try reel.frame(w, "secrets", hold: 1.4)
            try await palette(w, "redact sec", "secrets-palette")
            #expect(await f.eventually { f.model.document?.working.contains("AKIAIOSFODNN7EXAMPLE") == false })
            try await Task.sleep(for: .milliseconds(500))
            try reel.frame(w, "secrets-done", hold: 1.8)
        }
        // 7. Markdown
        do {
            let md = "# Release notes\n\n**4.2.1** fixes the *deploy* health check.\n\n- Faster uploads\n- Fewer `502`s\n- [Changelog](https://example.invalid/changelog)\n"
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: md, richRTFD: nil))
            defer { w.orderOut(nil); f.finish() }
            caption("Markdown, plain or previewed")
            try reel.frame(w, "markdown", hold: 1.3)
            key(w, "m", 46, [.command, .shift])
            try await Task.sleep(for: .milliseconds(700))
            try reel.frame(w, "markdown-preview", hold: 1.9)
        }
        // 8. ROT13 — the owner's own script
        do {
            let joke = "Why did the chicken cross the road?\n\nGb trg gb gur bgure fvqr.\n"
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: joke, richRTFD: nil)) { f in
                let script = "#!/usr/bin/env bash\n# pastefix: name = rot13\n\ntr 'A-Za-z' 'N-ZA-Mn-za-m'\n"
                let url = URL(fileURLWithPath: f.settings.scriptsDirectoryPath).appendingPathComponent("rot13.sh")
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                f.model.reload()
            }
            defer { w.orderOut(nil); f.finish() }
            caption("Your own scripts are transforms too — here on just the selection")
            // Select only the punchline, so the question stays readable (#25's selection scoping).
            let text = try #require(f.model.document?.working)
            let start = try #require(text.range(of: "Gb trg"))
            f.model.requestedSelection = TextSelection(range: start.lowerBound..<text.index(start.lowerBound, offsetBy: "Gb trg gb gur bgure fvqr.".count))
            try await Task.sleep(for: .milliseconds(500))
            try reel.frame(w, "rot13", hold: 1.3)
            try await palette(w, "rot13", "rot13-palette")
            #expect(await f.eventually { f.model.document?.working.contains("other side") == true })
            try await Task.sleep(for: .milliseconds(400))
            try reel.frame(w, "rot13-done", hold: 1.9)
        }
        // 9. History
        do {
            let (f, w) = try await fresh(ClipboardSnapshot(plainText: "Thanks — I'll take a look this afternoon.", richRTFD: nil)) { f in
                for t in ["https://github.com/bnaylor/pastefix/pull/138", "brew install --cask pastefix", "SELECT id, email FROM users WHERE active;", "Thanks — I'll take a look this afternoon."] {
                    _ = f.history.record(CaptureCandidate(plainText: t))
                }
                _ = f.history.pinText("Best,\nAda Lovelace\nAnalytical Engines Ltd.", richRTFD: nil, title: "Email signature")
            }
            defer { w.orderOut(nil); f.finish() }
            caption("Clipboard history, with pinned snippets")
            key(w, "y", 16, [.command])
            try await Task.sleep(for: .milliseconds(700))
            try reel.frame(w, "history", hold: 2.4)
        }
        try captions.write(to: reel.dir.appendingPathComponent("captions.txt"), atomically: true, encoding: .utf8)
    }
}
