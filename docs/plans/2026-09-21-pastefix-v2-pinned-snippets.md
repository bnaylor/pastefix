# Pastefix v2 Pinned Snippets & Hotkey Paste (Plan 9) — Implementation Plan

> ## 🟡 STATUS: IN PROGRESS — branch feat/pinned-snippets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; SwiftUI (Tasks 4–5) → `swiftui-pro`. **TDD is required** for the package task. App tasks are build-verified plus the controller's automated pass. **One implementer at a time on the branch.**

**Goal:** Pin history items or the editor buffer as snippets that never evict; a Pinned section in the ⌘⇧V overlay; ⇧↵ pastes any row into the previous app; per-snippet global hotkeys that paste into the frontmost app; a Snippets settings tab.

**Architecture:** Pins are a flag on `HistoryItem` (plus `pinnedAt`, `title`) with store rules (exempt from eviction and Clear, de-dup no-op) and search rules (pins first, title searchable) in `PastefixAppCore`, all unit-tested. The app adds `SnippetPaster` (Accessibility-gated ⌘V posting), `SnippetHotkeys` (per-pin `KeyboardShortcuts` names), `previousApp` on the tracker, overlay sections and keys, an editor pin popover, and a Snippets tab.

**Tech Stack:** Swift 6 SwiftPM (macOS 14+), Swift Testing; AppKit (`NSRunningApplication`, `CGEvent`, `AXIsProcessTrusted`), SwiftUI, KeyboardShortcuts (existing dependency).

**Spec:** `docs/specs/2026-09-21-pastefix-v2-pinned-snippets.md` — read it first.

## Global Constraints

- **Pins never evict and survive Clear History.** The item cap and byte budget count and evict unpinned items only. `clear()` removes unpinned items (and their blobs) and quarantined indexes; pins stay.
- **De-dup vs pins:** a `record` whose text/hash matches a pinned item returns that item unchanged (no move, no write).
- **Pinned ordering:** `pinnedAt` newest first in the Pinned section and in `pinnedItems`.
- **Search:** empty query → pins (newest-pinned first) then history; haystack for a pinned item = `title + "\n" + text` (title may be nil); sort tier, then pinned first, then original index.
- **Keys:** overlay ⌘P toggles pin (untitled) on the highlighted row; ⇧↵ pastes the row into the previous app; editor ⌘⇧P opens the pin popover. Both overlay keys are hidden key-equivalent `Button`s (the ⌘⌫ pattern), never `onKeyPress`.
- **Paste mechanics:** write clipboard (text + RTFD if any) → if target app given and not active, `activate()` → after 150 ms post ⌘V (virtual key 9, `.maskCommand`, key down then up, `.cghidEventTap`). Requires `AXIsProcessTrusted()`; otherwise copy-only and prompt via `AXIsProcessTrustedWithOptions` at most once per launch.
- **Hotkey names:** `KeyboardShortcuts.Name("snippet.<UUID uppercase string>")`; unpin → `reset` + `disable`.
- **Accessibility is only ever used to post ⌘V.** No event taps, no key observation. (AGENTS pattern note in Task 6.)
- **Branch:** `feat/pinned-snippets`. Conventional commits + `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #17. `main` is protected.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/PastefixAppCore/History/HistoryItem.swift` | `pinned`, `pinnedAt`, `title`; tolerant decoder |
| `Sources/PastefixAppCore/History/HistoryStore.swift` | pin API; eviction/clear/dedup rules |
| `Sources/PastefixAppCore/History/HistorySearch.swift` | pins first; title haystack |
| `Pastefix/Pastefix/FrontmostAppTracker.swift` | `previousApp` |
| `Pastefix/Pastefix/SnippetPaster.swift` (new) | trust check, clipboard write, ⌘V post |
| `Pastefix/Pastefix/SnippetHotkeys.swift` (new) | per-pin names, sync, handlers |
| `Pastefix/Pastefix/AppModel.swift` | `pinCurrentBuffer`, `togglePin`, `pasteIntoPreviousApp` |
| `Pastefix/Pastefix/HistoryOverlayView.swift` | sections, pinned rows, ⌘P, ⇧↵ |
| `Pastefix/Pastefix/PanelView.swift` | pin button + popover |
| `Pastefix/Pastefix/SettingsView.swift` | Snippets tab; Clear History caption |
| `Pastefix/Pastefix/PastefixApp.swift` | hotkey sync; previous-app injection |
| Tests: `HistoryStoreTests`, `HistorySearchTests` (extend) | |

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/pinned-snippets && swift test 2>&1 | tail -1` → `354 tests in 44 suites passed`.

---

### Task 1: Model, store rules, search (package, TDD)

**Files:** Modify `Sources/PastefixAppCore/History/HistoryItem.swift`, `HistoryStore.swift`, `HistorySearch.swift`; Tests `Tests/PastefixAppCoreTests/HistoryStoreTests.swift`, `HistorySearchTests.swift` (append).

**Produces:** `HistoryItem.pinned/pinnedAt/title`; `HistoryStore.pinnedItems/unpinnedItems/pin(_:title:)/unpin(_:)/rename(_:title:)/pinText(_:richRTFD:title:now:)`; search ordering.

- [ ] **Step 1: Failing tests** (append; use the file's existing `withDir`, `text(_:)`, `png(_:)` helpers)

```swift
    // HistoryStoreTests
    @Test func pinUnpinRenameAndOrdering() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let a = s.record(text("a"))!; let b = s.record(text("b"))!; s.record(text("c"))
            s.pin(a.id, title: "  Alpha "); s.pin(b.id)
            #expect(s.pinnedItems.map(\.id) == [b.id, a.id])            // newest pinned first
            #expect(s.pinnedItems.last?.title == "Alpha")
            s.rename(b.id, title: "  "); #expect(s.pinnedItems.first?.title == nil)
            s.unpin(a.id)
            #expect(s.pinnedItems.map(\.id) == [b.id] && s.unpinnedItems.count == 2)
            #expect(s.items.first { $0.id == a.id }?.pinnedAt == nil)
        }
    }
    @Test func pinTextCreatesOrPromotes() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let existing = s.record(text("boiler"))!
            let promoted = s.pinText("boiler", richRTFD: nil, title: "B")!
            #expect(promoted.id == existing.id && promoted.pinned && promoted.title == "B")
            let fresh = s.pinText("new snippet", richRTFD: Data([1]), title: nil)!
            #expect(fresh.pinned && fresh.kind == .richText && fresh.sourceAppName == nil)
            #expect(s.pinText(String(repeating: "x", count: 300_000), richRTFD: nil, title: nil) == nil)
        }
    }
    @Test func copyingAPinIsANoOp() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let p = s.record(text("pin me"))!; s.pin(p.id); s.record(text("later"))
            let before = s.items.map(\.id)
            let r = s.record(text("pin me"), now: Date(timeIntervalSince1970: 2_000_000_000))
            #expect(r?.id == p.id && s.items.map(\.id) == before && s.items.first { $0.id == p.id }?.capturedAt == p.capturedAt)
        }
    }
    @Test func pinsAreExemptFromCapAndByteEviction() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 2, maxImageBytes: 100, maxTotalBytes: 150))
            let p = s.record(text("keep"))!; s.pin(p.id)
            s.record(text("1")); s.record(text("2")); s.record(text("3"))
            #expect(s.items.contains { $0.id == p.id } && s.unpinnedItems.count == 2)
            let img = s.record(CaptureCandidate(imagePNG: png(1, size: 90)))!; s.pin(img.id)
            s.record(CaptureCandidate(imagePNG: png(2, size: 90))); s.record(CaptureCandidate(imagePNG: png(3, size: 90)))
            #expect(s.items.contains { $0.id == img.id })
        }
    }
    @Test func clearKeepsPinsAndTheirBlobs() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let p = s.pinText("rich pin", richRTFD: Data([7]), title: nil)!; s.record(text("gone"))
            s.clear()
            #expect(s.items.map(\.id) == [p.id] && s.richRTFD(for: p) == Data([7]))
        }
    }
    @Test func unpinReappliesCap() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir, limits: .init(maxItems: 1))
            let p = s.record(text("p"))!; s.pin(p.id); s.record(text("q"))
            s.unpin(p.id)
            #expect(s.items.count == 1 && s.items[0].plainText == "q")
        }
    }
    @Test func pinFieldsPersistAndOldIndexesLoad() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let p = s.record(text("x"))!; s.pin(p.id, title: "T"); s.flush()
            let s2 = HistoryStore(directory: dir)
            #expect(s2.items[0].pinned && s2.items[0].title == "T" && s2.items[0].pinnedAt != nil)
            // Pre-Plan-9 index: no pinned/pinnedAt/title keys.
            let legacy = #"[{"id":"00000000-0000-0000-0000-000000000001","capturedAt":"2026-09-01T00:00:00Z","plainText":"old","byteCount":3}]"#
            try Data(legacy.utf8).write(to: dir.appendingPathComponent("index.json"))
            let s3 = HistoryStore(directory: dir)
            #expect(s3.items.count == 1 && s3.items[0].pinned == false && s3.items[0].title == nil)
        }
    }

    // HistorySearchTests (new helper items: mark one pinned with a title)
    @Test func pinsComeFirstAndTitlesMatch() {
        var pinned = HistoryItem(plainText: "zeta body", sourceAppName: "Notes"); pinned.pinned = true; pinned.pinnedAt = Date(); pinned.title = "Signature"
        let plain = HistoryItem(plainText: "alpha body")
        let items = [plain, pinned]                                   // capture order: plain newest
        #expect(HistorySearch.rank(query: "", in: items).map(\.id) == [pinned.id, plain.id])
        #expect(HistorySearch.rank(query: "signat", in: items).first?.id == pinned.id)
        #expect(HistorySearch.rank(query: "body", in: items).map(\.id) == [pinned.id, plain.id])   // tie → pin first
    }
```

- [ ] **Step 2:** `swift test --filter "HistoryStoreTests|HistorySearchTests"` → compile errors.

- [ ] **Step 3: Implement**

`HistoryItem`: add `public var pinned: Bool`, `public var pinnedAt: Date?`, `public var title: String?` (init defaults `false`, `nil`, `nil`; add them to the memberwise init after `byteCount`). Add a custom decoder so older indexes load:
```swift
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        plainText = try c.decodeIfPresent(String.self, forKey: .plainText)
        richRTFDFile = try c.decodeIfPresent(String.self, forKey: .richRTFDFile)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imagePixelWidth = try c.decodeIfPresent(Int.self, forKey: .imagePixelWidth)
        imagePixelHeight = try c.decodeIfPresent(Int.self, forKey: .imagePixelHeight)
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
```
(the synthesized `encode(to:)` and `CodingKeys` remain).

`HistoryStore`:
```swift
    public var pinnedItems: [HistoryItem] { items.filter(\.pinned).sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) } }
    public var unpinnedItems: [HistoryItem] { items.filter { !$0.pinned } }

    public func pin(_ id: UUID, title: String? = nil, now: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = true; items[i].pinnedAt = now; items[i].title = Self.cleanTitle(title) ?? items[i].title
        flush()
    }
    public func unpin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = false; items[i].pinnedAt = nil; items[i].title = nil
        _ = enforceLimits(); flush()
    }
    public func rename(_ id: UUID, title: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = Self.cleanTitle(title); flush()
    }
    @discardableResult
    public func pinText(_ text: String, richRTFD: Data?, title: String?, now: Date = Date()) -> HistoryItem? {
        if let i = items.firstIndex(where: { $0.imageFile == nil && $0.plainText == text }) {
            pin(items[i].id, title: title, now: now); return items[i]
        }
        guard let created = record(CaptureCandidate(plainText: text, richRTFD: richRTFD), now: now) else { return nil }
        pin(created.id, title: title, now: now)
        return items.first { $0.id == created.id }
    }
    private static func cleanTitle(_ t: String?) -> String? { let s = t?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return s.isEmpty ? nil : s }
```
- `record` de-dup branch: `if items[existing].pinned { return items[existing] }` before the `existing == 0` check. Note: `pinText` on an over-budget text returns nil because `record` does.
- `enforceLimits`: replace the two loops so they only consider unpinned items:
```swift
        let cap = max(1, limits.maxItems)
        func evictOldestUnpinned() -> Bool {
            guard let i = items.lastIndex(where: { !$0.pinned }) else { return false }
            let victim = items.remove(at: i); deleteBlobs(ofItemWith: victim.id); return true
        }
        while unpinnedItems.count > cap, evictOldestUnpinned() { evicted = true }
        while totalBytes > limits.maxTotalBytes, unpinnedItems.count > 1, evictOldestUnpinned() { evicted = true }
```
(keep the existing "never evict the just-inserted item" property: `record` inserts at index 0 and `lastIndex(where:)` picks the oldest, so it holds while `unpinnedItems.count > 1`; for the cap loop the floor of 1 is preserved by `cap ≥ 1`.)
- `clear()`: `let victims = items.filter { !$0.pinned }; items.removeAll { !$0.pinned }; victims.forEach { deleteBlobs(ofItemWith: $0.id) }; removeQuarantinedIndexes(); flush()`.

`HistorySearch`:
```swift
        guard !q.isEmpty else {
            let pins = items.filter(\.pinned).sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
            return (pins + items.filter { !$0.pinned }).map { HistorySearchResult(item: $0, matchedRanges: [], tier: 0) }
        }
        …
        return hits.sorted { a, b in
            if a.0.tier != b.0.tier { return a.0.tier < b.0.tier }
            if a.0.item.pinned != b.0.item.pinned { return a.0.item.pinned }
            return a.1 < b.1
        }.map(\.0)
    static func haystack(for item: HistoryItem) -> String {
        let title = item.title.map { $0 + "\n" } ?? ""
        if item.hasText, let t = item.plainText { return title + String(t.prefix(haystackLimit)) }
        return title + "image \(item.sourceAppName ?? "")"
    }
```

- [ ] **Step 4:** filter green; full `swift test` green (update any existing test that asserted `clear()` empties everything only if it used pins — none do).
- [ ] **Step 5: Commit** `feat(appcore): pinned snippets — pin/unpin/rename/pinText, eviction and clear exemptions, pins-first search`.

---

### Task 2: Tracker `previousApp`, `SnippetPaster`, `SnippetHotkeys`, delegate sync

**Files:** Modify `Pastefix/Pastefix/FrontmostAppTracker.swift`, `PastefixApp.swift`; Create `SnippetPaster.swift`, `SnippetHotkeys.swift`.

- [ ] **Step 1: Tracker** — add `private(set) var previousApp: NSRunningApplication?` and `private var currentApp: NSRunningApplication?`. In `init`, `currentApp = workspace.frontmostApplication`. In the activation handler, before `record`: `if let cur = currentApp, cur.bundleIdentifier != Bundle.main.bundleIdentifier, cur.processIdentifier != app.processIdentifier { previousApp = cur }; currentApp = app`. Doc comment: "the app to paste into after Pastefix hides".

- [ ] **Step 2: `SnippetPaster.swift`**
```swift
import AppKit
import ApplicationServices

/// Puts a snippet on the clipboard and pastes it into another app by posting ⌘V. Accessibility
/// permission is required to post the key event; Pastefix uses it for nothing else — no event
/// tap, no key observation.
@MainActor
enum SnippetPaster {
    enum Outcome { case pasted, copiedOnly }
    private static var promptedThisLaunch = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt at most once per launch. Returns the current trust state.
    @discardableResult
    static func ensureTrusted() -> Bool {
        if isTrusted { return true }
        guard !promptedThisLaunch else { return false }
        promptedThisLaunch = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func paste(text: String, richRTFD: Data?, into app: NSRunningApplication?) -> Outcome {
        ClipboardBridge.write(text: text, richRTFD: richRTFD, imagePNG: nil)
        guard ensureTrusted() else { return .copiedOnly }
        if let app, !app.isActive { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { postCommandV() }
        return .pasted
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}
```

- [ ] **Step 3: `SnippetHotkeys.swift`**
```swift
import AppKit
import KeyboardShortcuts
import PastefixAppCore

/// One global shortcut per pinned snippet, named by the item id. Handlers live for the process
/// (the library has no unregister); an unpinned id's handler is a no-op because the lookup fails.
@MainActor
final class SnippetHotkeys {
    private let history: HistoryStore
    private var registered: Set<UUID> = []

    init(history: HistoryStore) { self.history = history }

    static func name(for id: UUID) -> KeyboardShortcuts.Name { .init("snippet.\(id.uuidString)") }

    func sync() {
        let pinned = Set(history.pinnedItems.map(\.id))
        for id in pinned.subtracting(registered) {
            KeyboardShortcuts.onKeyUp(for: Self.name(for: id)) { [weak self] in
                MainActor.assumeIsolated { self?.fire(id) }
            }
            registered.insert(id)
        }
        for id in registered.subtracting(pinned) {
            KeyboardShortcuts.reset(Self.name(for: id))
            KeyboardShortcuts.disable(Self.name(for: id))
            registered.remove(id)
        }
        for id in pinned { KeyboardShortcuts.enable(Self.name(for: id)) }
    }

    private func fire(_ id: UUID) {
        guard let item = history.items.first(where: { $0.id == id && $0.pinned }), let text = item.plainText else { return }
        _ = SnippetPaster.paste(text: text, richRTFD: history.richRTFD(for: item), into: NSWorkspace.shared.frontmostApplication)
    }
}
```
If `KeyboardShortcuts.enable/disable` aren't available in the pinned version, drop those two calls and rely on `reset` (a reset shortcut can't fire).

- [ ] **Step 4: `AppDelegate`** — `private(set) lazy var snippetHotkeys = SnippetHotkeys(history: history)`; after the monitor setup: `snippetHotkeys.sync()` and
```swift
        history.$items
            .map { Set($0.filter(\.pinned).map(\.id)) }
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.snippetHotkeys.sync() } }
            .store(in: &cancellables)
```
Also give `AppModel` the previous-app provider: `model.previousAppProvider = { [weak self] in self?.frontmostTracker.previousApp }` (property added in Task 3; if Task 3 hasn't landed yet, add the property in this task as `var previousAppProvider: () -> NSRunningApplication? = { nil }` on `AppModel` — coordinate: Task 3 uses it).

- [ ] **Step 5: Build** (`xcodebuild … | grep -E "error:|warning:|BUILD"` → BUILD SUCCEEDED, no new warnings). `swift test` unchanged.
- [ ] **Step 6: Commit** `feat(app): SnippetPaster (Accessibility-gated ⌘V), per-pin SnippetHotkeys, tracker previousApp`.

---

### Task 3: `AppModel` actions + overlay sections/keys

**Files:** Modify `Pastefix/Pastefix/AppModel.swift`, `HistoryOverlayView.swift`.

- [ ] **Step 1: `AppModel`**
```swift
    var previousAppProvider: () -> NSRunningApplication? = { nil }   // if not already added in Task 2

    func togglePin(_ item: HistoryItem) { item.pinned ? history.unpin(item.id) : history.pin(item.id) }

    /// Pins the editor buffer (with the origin's rich data). Returns false when over budget.
    @discardableResult
    func pinCurrentBuffer(title: String?) -> Bool {
        guard let doc = document else { return false }
        return history.pinText(doc.working, richRTFD: doc.origin.richRTFD, title: title) != nil
    }

    /// Copies the item, hides the panel, and pastes into the app the user came from.
    func pasteIntoPreviousApp(_ item: HistoryItem) {
        let text = item.plainText ?? ""
        let rich = history.richRTFD(for: item)
        let target = previousAppProvider()
        endSession()
        _ = SnippetPaster.paste(text: text, richRTFD: rich, into: target)
    }
```
- [ ] **Step 2: Overlay**
  - Rows: pinned → leading `Image(systemName: "pin.fill").foregroundStyle(Color.accentColor)`; if `title` set, a bold `Text(title)` line above the preview (preview then `.lineLimit(1)` to keep row height); trailing label unchanged.
  - Sections: when `query.trimmingCharacters(in: .whitespaces).isEmpty` and `results.contains { $0.item.pinned }`, render `List { Section("Pinned") { rows for the pinned prefix }; Section("History") { the rest } }` — `results` is already pins-first, so the split index is the first unpinned result; global `selection` indices stay valid (same order). Otherwise the existing flat list. Row height budget: keep `rowHeight`; the `visibleRows` derivation reserves one extra row's height for the section headers when sectioned.
  - Hidden key equivalents beside the ⌘Y/⌘⌫ ones: `Button("") { togglePinSelected() }.keyboardShortcut("p", modifiers: .command)` and `Button("") { pasteSelected() }.keyboardShortcut(.return, modifiers: .shift)`; both read the live `@State results`.
  - `togglePinSelected()`: `guard let item = selectedItem() else { return }; model.togglePin(item)` (results refresh via the existing items observer). `pasteSelected()`: `guard let item = selectedItem() else { return }; onClose(); model.pasteIntoPreviousApp(item)`.
  - Footer: `"↵ Open   ⌘↵ Copy   ⇧↵ Paste   ⌘P Pin   ⌘⌫ Remove   esc Close"`.
- [ ] **Step 3: Build** → BUILD SUCCEEDED, no new warnings.
- [ ] **Step 4: Commit** `feat(app): overlay Pinned section, ⌘P pin toggle, ⇧↵ paste into previous app`.

---

### Task 4: Editor pin popover

**Files:** Modify `Pastefix/Pastefix/PanelView.swift`.

- [ ] Toolbar button after Refresh: `Button { showPinPopover = true } label: { Image(systemName: "pin") }.help("Pin this text as a snippet (⌘⇧P)").keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.document == nil || isPaletteOpen || isHistoryOpen)` with
```swift
    .popover(isPresented: $showPinPopover, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pin as snippet").font(.headline)
            TextField("Title (optional)", text: $pinTitle).frame(width: 260).onSubmit(commitPin)
            if pinError != nil { Text(pinError!).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { showPinPopover = false }; Button("Pin", action: commitPin).keyboardShortcut(.defaultAction) }
        }.padding()
    }
```
and `private func commitPin() { if model.pinCurrentBuffer(title: pinTitle) { pinTitle = ""; pinError = nil; showPinPopover = false } else { pinError = "Too large to pin" } }` with `@State` vars `showPinPopover`, `pinTitle`, `pinError: String?`.
- [ ] Build → BUILD SUCCEEDED. Commit `feat(app): pin the editor buffer as a snippet (⌘⇧P) with an optional title`.

---

### Task 5: Settings → Snippets tab

**Files:** Modify `Pastefix/Pastefix/SettingsView.swift`.

- [ ] Add `snippets.tabItem { Label("Snippets", systemImage: "pin") }` after Privacy. Content:
```swift
    private var snippets: some View {
        Form {
            Section("Paste with hotkey") {
                HStack {
                    Image(systemName: SnippetPaster.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(SnippetPaster.isTrusted ? .green : .orange)
                    Text(SnippetPaster.isTrusted ? "Ready — snippet hotkeys paste into the frontmost app."
                                                 : "Needs Accessibility permission to press ⌘V for you. Until then hotkeys copy the snippet only.")
                    Spacer()
                    if !SnippetPaster.isTrusted {
                        Button("Request…") { _ = SnippetPaster.ensureTrusted() }
                        Button("Open System Settings") { SnippetPaster.openAccessibilitySettings() }
                    }
                }
                Text("Pastefix uses Accessibility only to send ⌘V. It never reads your keystrokes.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pinned snippets") {
                if history.pinnedItems.isEmpty {
                    Text("No pinned snippets yet. Pin from the history overlay (⌘P) or the editor (⌘⇧P).").foregroundStyle(.secondary)
                } else {
                    ForEach(history.pinnedItems) { item in
                        SnippetRow(item: item, history: history)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 400)
    }
```
```swift
struct SnippetRow: View {
    let item: HistoryItem
    @ObservedObject var history: HistoryStore
    @State private var title: String
    init(item: HistoryItem, history: HistoryStore) { self.item = item; self.history = history; _title = State(initialValue: item.title ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    .onSubmit { history.rename(item.id, title: title) }
                Spacer()
                KeyboardShortcuts.Recorder("", name: SnippetHotkeys.name(for: item.id))
                Button("Unpin") { history.unpin(item.id) }
            }
            Text(HistoryFormatting.previewText(for: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
```
  Refresh the trust indicator when the window comes to front: `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trustTick += 1 }` with a `@State private var trustTick = 0` referenced in the section (`.id(trustTick)`).
- [ ] Privacy tab: Clear History caption → "Items marked private by password managers are never recorded. Pinned snippets are kept." and the alert message → "This removes every remembered item and its files from disk. Pinned snippets are kept."
- [ ] Build → BUILD SUCCEEDED. Commit `feat(app): Snippets settings tab — titles, per-snippet hotkeys, unpin, Accessibility status`.

---

### Task 6: Documentation

- [ ] README: "Pinned snippets" section (pin from overlay ⌘P / editor ⌘⇧P; Pinned section; ⇧↵ paste into the previous app; per-snippet hotkeys in Settings → Snippets; Accessibility only for ⌘V, copy-only fallback; Clear History keeps pins; images can't be pinned yet). Settings list: Snippets tab.
- [ ] AGENTS.md: layout (`SnippetPaster.swift`, `SnippetHotkeys.swift`); Patterns: "Accessibility is requested only to post ⌘V (`SnippetPaster`); Pastefix never installs an event tap or observes keystrokes — keep it that way"; status row Plan 9 (🟡). No bitten-us entries.
- [ ] Plan banner → 🟡 IN PROGRESS. Commit `docs: pinned snippets — README, AGENTS layout + Accessibility pattern`.

---

### Task 7: Automated app pass (controller) and finish

- [ ] Build Debug; quit any Pastefix; launch. Copy "alpha", "beta"; ⌘⇧V, ⌘P → `index.json` shows the top item `pinned: true`; relaunch → still pinned; set `historyMaxItems` low via defaults and copy past it → pin survives.
- [ ] Editor: ⌘⇧C with text, ⌘⇧P, type "Sig", ↵ → pinned item with `title: "Sig"`.
- [ ] Hotkey: write the KeyboardShortcuts binding for `snippet.<uuid>` into `scromp.net.Pastefix` defaults (key `KeyboardShortcuts_snippet.<uuid>`, value the library's JSON `{"carbonKeyCode":1,"carbonModifiers":…}` — inspect an existing `KeyboardShortcuts_summonPastefix` entry to copy the format), relaunch, grant Accessibility to the Debug build when prompted (the one manual click), open TextEdit with a new document, press the combo via System Events, read the document text via AppleScript → the snippet.
- [ ] ⇧↵: TextEdit frontmost → ⌘⇧V → ⇧↵ on a row → text lands in TextEdit.
- [ ] Screenshot: overlay with Pinned + History sections; Snippets tab.
- [ ] Final whole-branch review, one fix wave, AGENTS "bitten us", push, PR closing #17, `git checkout main`.

---

## Self-review

- **Spec coverage:** model + rules + search (T1); tracker/paster/hotkeys/sync (T2); overlay + actions (T3); editor pin (T4); Settings (T5); docs (T6); pass (T7).
- **Type consistency:** `HistoryStore.pin(_:title:now:)`, `unpin`, `rename(_:title:)`, `pinText(_:richRTFD:title:now:)`, `pinnedItems`, `unpinnedItems`; `SnippetPaster.paste(text:richRTFD:into:) -> Outcome`, `isTrusted`, `ensureTrusted()`, `openAccessibilitySettings()`; `SnippetHotkeys.name(for:)`, `sync()`; `FrontmostAppTracker.previousApp`; `AppModel.togglePin/pinCurrentBuffer(title:)/pasteIntoPreviousApp/previousAppProvider` — consistent across tasks.
- **Placeholders:** the KeyboardShortcuts defaults format in T7 is "inspect an existing entry" by design (library-internal); everything else concrete.
