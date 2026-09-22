# Pastefix v2 Markdown Preview (Plan 10) — Implementation Plan

> ## ✅ STATUS: COMPLETE — merged to main via PR #40 (`c98cca8`, 2026-09-21)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; SwiftUI/AppKit (Task 2) → `swiftui-pro`. **TDD is required** for the package task. **One implementer at a time on the branch.**

**Goal:** A toggleable, read-only rendered preview of the working buffer in the panel (⌘⇧M), reusing the Plan 8 renderer, with no network access and correct dark-mode text.

**Architecture:** `PastefixAppCore` gains `MarkdownPreview.attributedString(markdown:)` (Markdown → HTML → images stripped → stylesheet → `NSAttributedString(html:)` → foreground colours stripped except links; 64 KB cap; raw-text fallback). The app gains `MarkdownPreviewView` (`NSTextView` in an `NSViewRepresentable`) and a toolbar toggle in `PanelView` with debounced re-rendering and Esc arbitration.

**Tech Stack:** Swift 6 SwiftPM (macOS 14+), AppKit `NSAttributedString(html:)`/`NSTextView`, SwiftUI, Swift Testing.

**Spec:** `docs/specs/2026-09-21-pastefix-v2-markdown-preview.md` — read it first.

## Global Constraints

- **No network:** the HTML handed to the importer goes through `RichOutputRenderer.htmlForRTF` (strips `<img>`), exactly as the RTF path does.
- **Cap:** `MarkdownPreview.maxBytes = 65_536` (UTF-8); above it return the notice string "Preview is limited to 64 KB of Markdown." as an attributed string, no rendering.
- **Colours:** remove `.foregroundColor` from every run except those with a `.link` attribute; the text view uses `labelColor`.
- **Stylesheet (prepended, verbatim):** `<style>body{font-family:-apple-system,system-ui;font-size:13px;line-height:1.35}code,pre{font-family:Menlo,monospace;font-size:12px}h1{font-size:22px}h2{font-size:18px}h3{font-size:15px}blockquote{margin-left:12px;padding-left:8px}</style>`
- **Keys:** ⌘⇧M toggles preview; Esc order = palette → history → preview → cancel; a session change (`model.sessionGeneration`) resets preview off.
- **Debounce:** 150 ms after the last buffer change before re-rendering; render on the main actor.
- **Branch:** `feat/markdown-preview`. Conventional commits + `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #15. `main` is protected.

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/markdown-preview && swift test 2>&1 | tail -1` → `365 tests in 44 suites passed`.

---

### Task 1: `MarkdownPreview` (package, TDD)

**Files:** Create `Sources/PastefixAppCore/MarkdownPreview.swift`; Test `Tests/PastefixAppCoreTests/MarkdownPreviewTests.swift`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
import AppKit
@testable import PastefixAppCore

@MainActor
@Suite struct MarkdownPreviewTests {
    private func runs(_ s: NSAttributedString) -> [(String, [NSAttributedString.Key: Any])] {
        var out: [(String, [NSAttributedString.Key: Any])] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, range, _ in
            out.append(((s.string as NSString).substring(with: range), attrs))
        }
        return out
    }
    private func font(_ attrs: [NSAttributedString.Key: Any]) -> NSFont? { attrs[.font] as? NSFont }

    @Test func headingIsLargerThanBody() {
        let s = MarkdownPreview.attributedString(markdown: "# Title\n\nbody text")
        let all = runs(s)
        let h = all.first { $0.0.contains("Title") }.flatMap { font($0.1) }
        let b = all.first { $0.0.contains("body") }.flatMap { font($0.1) }
        #expect(h != nil && b != nil && h!.pointSize > b!.pointSize)
    }
    @Test func inlineCodeIsMonospaced() {
        let s = MarkdownPreview.attributedString(markdown: "call `foo()` now")
        let code = runs(s).first { $0.0 == "foo()" }.flatMap { font($0.1) }
        #expect(code != nil && (code!.fontDescriptor.symbolicTraits.contains(.monoSpace) || (code!.familyName ?? "").contains("Menlo")))
    }
    @Test func foregroundColoursStrippedExceptLinks() {
        let s = MarkdownPreview.attributedString(markdown: "plain **bold** and [site](https://a.b)")
        for (text, attrs) in runs(s) {
            if attrs[.link] != nil { #expect(text == "site") }
            else { #expect(attrs[.foregroundColor] == nil, "run \(text) still carries a colour") }
        }
        #expect(runs(s).contains { $0.1[.link] != nil })
    }
    @Test func overCapReturnsNotice() {
        let s = MarkdownPreview.attributedString(markdown: String(repeating: "a", count: MarkdownPreview.maxBytes + 1))
        #expect(s.string == "Preview is limited to 64 KB of Markdown.")
    }
    @Test func malformedStillRendersSomething() {
        let s = MarkdownPreview.attributedString(markdown: "[unclosed(\n\n**bold")
        #expect(!s.string.isEmpty && s.string.contains("bold"))
    }
    @Test func imagesProduceNoAttachment() {
        let s = MarkdownPreview.attributedString(markdown: "![p](https://example.invalid/pixel.png) text")
        #expect(!s.string.contains("\u{FFFC}") && s.string.contains("text"))
    }
}
```
- [ ] **Step 2:** `swift test --filter MarkdownPreviewTests` → compile errors.
- [ ] **Step 3: Implement**
```swift
import Foundation
import AppKit
import PastefixCore

/// Read-only rendering of the buffer for the panel's Preview toggle. Shares the armed-save
/// pipeline: same HTML renderer, same `<img>` stripping (no network), plus a stylesheet and a
/// colour strip so the text follows the system appearance.
public enum MarkdownPreview {
    public static let maxBytes = 65_536
    static let notice = "Preview is limited to 64 KB of Markdown."
    static let stylesheet = "<style>body{font-family:-apple-system,system-ui;font-size:13px;line-height:1.35}code,pre{font-family:Menlo,monospace;font-size:12px}h1{font-size:22px}h2{font-size:18px}h3{font-size:15px}blockquote{margin-left:12px;padding-left:8px}</style>"

    @MainActor
    public static func attributedString(markdown: String) -> NSAttributedString {
        guard markdown.utf8.count <= maxBytes else { return plain(notice) }
        guard let html = try? MarkdownHTML.render(markdown) else { return plain(markdown, mono: true) }
        let body = RichOutputRenderer.htmlForRTF(html)
        guard let imported = NSMutableAttributedString(html: Data((stylesheet + body).utf8),
                                                       options: [.documentType: NSAttributedString.DocumentType.html,
                                                                 .characterEncoding: String.Encoding.utf8.rawValue],
                                                       documentAttributes: nil) else { return plain(markdown, mono: true) }
        stripForegroundColors(imported)
        return imported
    }

    static func stripForegroundColors(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttributes(in: full) { attrs, range, _ in
            if attrs[.link] == nil, attrs[.foregroundColor] != nil { s.removeAttribute(.foregroundColor, range: range) }
        }
    }

    private static func plain(_ text: String, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13)])
    }
}
```
If `RichOutputRenderer.htmlForRTF` is `internal` it is visible inside the module already. If the importer ignores the stylesheet's `font-family` for `code` (it usually honours it), the mono test also accepts the `.monoSpace` trait — verify with a scratch run and adjust the stylesheet (e.g. `font-family:Menlo`) rather than the test.
- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(appcore): MarkdownPreview — appearance-safe attributed rendering for the panel preview`.

---

### Task 2: Preview view and panel toggle

**Files:** Create `Pastefix/Pastefix/MarkdownPreviewView.swift`; Modify `Pastefix/Pastefix/PanelView.swift`.

- [ ] **Step 1: `MarkdownPreviewView.swift`**
```swift
import SwiftUI
import AppKit

/// Read-only, selectable rendering of the buffer. Replaces the editor while previewing.
struct MarkdownPreviewView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textColor = .labelColor
        tv.isAutomaticLinkDetectionEnabled = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.textStorage?.isEqual(to: text) != true else { return }
        tv.textStorage?.setAttributedString(text)
        tv.textColor = .labelColor
    }
}
```
- [ ] **Step 2: `PanelView`**
  - State: `@State private var isPreviewing = false`, `@State private var previewText = NSAttributedString()`, `@State private var previewTask: Task<Void, Never>?`.
  - Editor area: replace the `TextEditor` line with
    ```swift
    if isPreviewing {
        MarkdownPreviewView(text: previewText)
            .padding(8)
    } else {
        TextEditor(text: workingBinding)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .disabled(model.isApplying)
            .focused($editorFocused)
    }
    ```
  - Toolbar button after the pin button:
    ```swift
    Button { togglePreview() } label: { Image(systemName: isPreviewing ? "eye.fill" : "eye") }
        .help(isPreviewing ? "Back to the editor (⌘⇧M)" : "Preview as Markdown (⌘⇧M)")
        .tint(model.document?.detectedKinds.contains(.markdown) == true ? Color.accentColor : nil)
        .keyboardShortcut(isPaletteOpen || isHistoryOpen ? nil : KeyboardShortcut("m", modifiers: [.command, .shift]))
        .disabled(model.document == nil || model.isApplying)
    ```
  - Rendering:
    ```swift
    private func scheduleRender(immediate: Bool = false) {
        previewTask?.cancel()
        let text = model.document?.working ?? ""
        previewTask = Task { @MainActor in
            if !immediate { try? await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return } }
            previewText = MarkdownPreview.attributedString(markdown: text)
        }
    }
    private func togglePreview() {
        if isPreviewing { closePreview() } else { isPreviewing = true; scheduleRender(immediate: true) }
    }
    private func closePreview() { isPreviewing = false; previewTask?.cancel(); editorFocused = true }
    ```
    plus `.onChange(of: model.document?.working) { _, _ in if isPreviewing { scheduleRender() } }` and, in the existing `sessionGeneration` `onChange`, `isPreviewing = false`.
  - `escape()`: `if isPaletteOpen { closePalette() } else if isHistoryOpen { closeHistory() } else if isPreviewing { closePreview() } else { model.cancel() }`.
  - The "refocus editor after apply" `onChange` must skip when `isPreviewing`.
- [ ] **Step 3: Build** `xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:|BUILD"` → BUILD SUCCEEDED, no new warnings. `swift test` unchanged.
- [ ] **Step 4: Commit** `feat(app): Markdown preview toggle (⌘⇧M) replacing the editor; Esc returns to the editor`.

---

### Task 3: Docs

- [ ] README: under "Markdown and rich text": "**Preview.** The eye button (⌘⇧M) swaps the editor for a read-only rendering of the buffer as Markdown; it's tinted when Markdown is detected. Images aren't shown and previews are limited to 64 KB. Esc returns to the editor."
- [ ] AGENTS.md: layout entries; Patterns: "The preview shares the RTF pipeline's `<img>` stripping (`RichOutputRenderer.htmlForRTF`) — the importer is WebKit-backed and must never be handed an `<img>`"; status row Plan 10 (🟡). Plan banner → 🟡. Commit `docs: Markdown preview — README, AGENTS`.

---

### Task 4: Automated pass (controller) and finish

- [ ] Markdown on the clipboard → ⌘⇧C → ⌘⇧M → screenshot (headings/list rendered, dark-mode text legible); type → toggle → updated; Esc → editor (panel still open); Esc → cancel; ⌘K over the preview; new summon starts in the editor. Restore the user's clipboard afterwards.
- [ ] Final review (light: single reviewer over the whole branch), fix wave if needed, push, PR closing #15, `git checkout main`.

## Self-review
- Spec coverage: renderer + cap + colours (T1); view + toggle + debounce + Esc + reset (T2); docs (T3); pass (T4).
- Types: `MarkdownPreview.attributedString(markdown:)`, `.maxBytes`; `MarkdownPreviewView(text:)`.
