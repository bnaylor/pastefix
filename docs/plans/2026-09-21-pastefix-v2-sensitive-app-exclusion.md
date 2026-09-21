# Pastefix v2 Sensitive-App Exclusion (Plan 7) — Implementation Plan

> ## ⬜ STATUS: NOT STARTED — written 2026-09-21 from the approved spec (issue #10).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; SwiftUI (Task 4) → `swiftui-pro`. **TDD is required** for every `PastefixAppCore` task. **One implementer at a time on the branch.**

**Goal:** Clipboard history never records items copied from password managers or other user-listed apps; the source app is known before the pasteboard is read; a menu-bar item pauses capture.

**Architecture:** The filter decision logic (`CaptureContext`, `CaptureFilter`, `ConcealedTypeFilter`, `AppExclusionFilter`, `ExclusionSeeds`, `RecentApps`) moves into `PastefixAppCore/Capture/` and is unit-tested. The app gains a `FrontmostAppTracker` fed by workspace activation notifications; `PasteboardMonitor` builds a `CaptureContext` from it before every read and hands it to both stages, refreshing it after the read. Settings gets a Privacy tab; the menu bar gets a Clipboard History toggle and a pause glyph.

**Tech Stack:** Swift 6 SwiftPM (`PastefixAppCore` already imports AppKit for `ClipboardSnapshot`; `NSPasteboard.PasteboardType` is allowed there), Swift Testing, SwiftUI/AppKit app target.

**Spec:** `docs/specs/2026-09-21-pastefix-v2-sensitive-app-exclusion.md` — read it first.

## Global Constraints

- **Never read, never record:** if the source app or any app frontmost within the poll window (`windowSeconds` = 1.0) is excluded, stage 1 returns false and the content is not read. Stage 2 re-checks with a refreshed context.
- **Match rule:** bundle id, exact, case-insensitive. `nil` source matches nothing.
- **Seeds (order and spelling verbatim):** `com.1password.1password`, `com.agilebits.onepassword7`, `com.bitwarden.desktop`, `com.apple.keychainaccess`, `com.apple.Passwords`, `com.dashlane.dashlanephonefinal`, `com.lastpass.LastPass`, `org.keepassxc.keepassxc`, `in.sinew.Enpass-Desktop`, `com.nordpass.macos`, `me.proton.pass.electron`, `com.markmcguill.strongbox.mac`.
- **Setting:** `historyExcludedBundleIDs: [String]`, key `pastefix.historyExcludedBundleIDs`, JSON array via the existing `writeJSON/readJSON` helpers; absent key → seeds; stored empty array stays empty.
- **Menu bar:** item title "Clipboard History" (checkmark toggle bound to `historyEnabled`); icon `doc.on.clipboard` when on, `pause.circle` when off.
- **Settings tab:** "Privacy", `hand.raised`; History section moves there from General; window stays 460×400.
- **Critical Invariant 12** (amended in Task 5): adds "the source app is determined before the read from a notification-fed tracker, and every app frontmost within the poll window is checked against the exclusion list".
- **Branch:** `feat/sensitive-app-exclusion`. Conventional commits + `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #10.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/PastefixAppCore/Capture/CaptureContext.swift` (new) | `CaptureContext`, `CaptureFilter` protocol |
| `Sources/PastefixAppCore/Capture/ConcealedTypeFilter.swift` (new, moved) | marker filter |
| `Sources/PastefixAppCore/Capture/AppExclusionFilter.swift` (new) | bundle-id filter |
| `Sources/PastefixAppCore/Capture/ExclusionSeeds.swift` (new) | seed list |
| `Sources/PastefixAppCore/Capture/RecentApps.swift` (new) | pure windowing helper |
| `Sources/PastefixAppCore/SettingsStore.swift` | exclusion list setting + mutators |
| `Pastefix/Pastefix/FrontmostAppTracker.swift` (new) | activation tracking |
| `Pastefix/Pastefix/PasteboardMonitor.swift` | context in both stages; app-side filter types removed |
| `Pastefix/Pastefix/PastefixApp.swift` | tracker, filter rebuild, menu toggle + icon |
| `Pastefix/Pastefix/SettingsView.swift` | Privacy tab |
| Tests: `AppExclusionFilterTests`, `ConcealedTypeFilterTests`, `RecentAppsTests`, `ExclusionSeedsTests` (new); `SettingsStoreTests` (extend) | |
| `README.md`, `AGENTS.md`, Plan 6 spec | currency |

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/sensitive-app-exclusion && swift test 2>&1 | tail -1` → `290 tests in 35 suites passed`.

---

### Task 1: Capture filters in the package (and the monitor adapted to them)

**Files:**
- Create: `Sources/PastefixAppCore/Capture/CaptureContext.swift`, `ConcealedTypeFilter.swift`, `AppExclusionFilter.swift`, `ExclusionSeeds.swift`, `RecentApps.swift`
- Modify: `Pastefix/Pastefix/PasteboardMonitor.swift` (delete the app-side `CaptureFilter` and `ConcealedTypeFilter`; call the new signatures with a placeholder `CaptureContext()` — Task 3 supplies the real one)
- Test: `Tests/PastefixAppCoreTests/AppExclusionFilterTests.swift`, `ConcealedTypeFilterTests.swift`, `RecentAppsTests.swift`, `ExclusionSeedsTests.swift`

**Produces:** the public API below, consumed by Tasks 2–4.

- [ ] **Step 1: Failing tests**

```swift
// AppExclusionFilterTests.swift
import Testing
import AppKit
@testable import PastefixAppCore

@Suite struct AppExclusionFilterTests {
    let f = AppExclusionFilter(excludedBundleIDs: ["com.1password.1password", "COM.Bitwarden.Desktop"])
    let noTypes: [NSPasteboard.PasteboardType] = [.string]
    func both(_ ctx: CaptureContext) -> (Bool, Bool) {
        (f.shouldRead(types: noTypes, context: ctx), f.shouldCapture(CaptureCandidate(plainText: "x"), types: noTypes, context: ctx))
    }
    @Test func excludedSourceRejectsBothStages() {
        #expect(both(CaptureContext(sourceBundleID: "com.1password.1password", recentBundleIDs: ["com.1password.1password"])) == (false, false))
    }
    @Test func excludedAppOnlyInRecentsRejects() {
        #expect(both(CaptureContext(sourceBundleID: "com.apple.Safari", recentBundleIDs: ["com.apple.Safari", "com.1password.1password"])) == (false, false))
    }
    @Test func matchIsCaseInsensitive() {
        #expect(f.isExcluded("com.bitwarden.desktop") && f.isExcluded("COM.1PASSWORD.1PASSWORD"))
        #expect(both(CaptureContext(sourceBundleID: "com.bitwarden.desktop", recentBundleIDs: [])) == (false, false))
    }
    @Test func unrelatedAppPasses() {
        #expect(both(CaptureContext(sourceBundleID: "com.apple.Safari", recentBundleIDs: ["com.apple.Safari"])) == (true, true))
    }
    @Test func nilSourceAndEmptyRecentsPass() { #expect(both(CaptureContext()) == (true, true)) }
    @Test func emptyListPassesEverything() {
        let e = AppExclusionFilter(excludedBundleIDs: [])
        #expect(e.shouldRead(types: noTypes, context: CaptureContext(sourceBundleID: "com.1password.1password", recentBundleIDs: ["com.1password.1password"])))
    }
}

// ConcealedTypeFilterTests.swift
import Testing
import AppKit
@testable import PastefixAppCore

@Suite struct ConcealedTypeFilterTests {
    let f = ConcealedTypeFilter()
    let ctx = CaptureContext(sourceBundleID: "com.apple.Safari", recentBundleIDs: ["com.apple.Safari"])
    @Test(arguments: ConcealedTypeFilter.markers.map(\.rawValue))
    func eachMarkerRejectsBothStages(marker: String) {
        let types: [NSPasteboard.PasteboardType] = [.string, .init(marker)]
        #expect(!f.shouldRead(types: types, context: ctx))
        #expect(!f.shouldCapture(CaptureCandidate(plainText: "x"), types: types, context: ctx))
    }
    @Test func plainTypesPass() {
        #expect(f.shouldRead(types: [.string, .rtf], context: ctx))
        #expect(f.shouldCapture(CaptureCandidate(plainText: "x"), types: [.string], context: CaptureContext()))
    }
    @Test func sixMarkers() { #expect(ConcealedTypeFilter.markers.count == 6) }
}

// RecentAppsTests.swift
import Testing
import Foundation
@testable import PastefixAppCore

@Suite struct RecentAppsTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func e(_ id: String, _ dt: TimeInterval) -> RecentApps.Entry { .init(bundleID: id, appName: id, activatedAt: t0.addingTimeInterval(dt)) }
    @Test func singleEntry() {
        #expect(RecentApps.window(entries: [e("a", 0)], now: t0.addingTimeInterval(10), window: 1) == ["a"])
    }
    @Test func switchInsideWindowKeepsBoth() {
        // b became frontmost 0.3 s ago; a was frontmost until then, i.e. inside the last 1 s.
        #expect(RecentApps.window(entries: [e("a", 0), e("b", 9.7)], now: t0.addingTimeInterval(10), window: 1) == ["b", "a"])
    }
    @Test func switchOutsideWindowKeepsNewestOnly() {
        #expect(RecentApps.window(entries: [e("a", 0), e("b", 5)], now: t0.addingTimeInterval(10), window: 1) == ["b"])
    }
    @Test func repeatedIdsDeduplicatedNewestFirst() {
        #expect(RecentApps.window(entries: [e("a", 9.2), e("b", 9.5), e("a", 9.8)], now: t0.addingTimeInterval(10), window: 1) == ["a", "b"])
    }
    @Test func emptyEntries() { #expect(RecentApps.window(entries: [], now: t0, window: 1).isEmpty) }
    @Test func trimDropsEntriesOlderThanRetentionButKeepsTheCurrent() {
        let kept = RecentApps.trimmed([e("a", 0), e("b", 1), e("c", 9)], now: t0.addingTimeInterval(10), retention: 5)
        #expect(kept.map(\.bundleID) == ["b", "c"])   // b is the entry that was current when c took over inside retention; a is fully outside
    }
}

// ExclusionSeedsTests.swift
import Testing
@testable import PastefixAppCore

@Suite struct ExclusionSeedsTests {
    @Test func twelveUniqueIds() {
        let s = ExclusionSeeds.passwordManagers
        #expect(s.count == 12 && Set(s.map { $0.lowercased() }).count == 12)
        #expect(s.contains("com.1password.1password") && s.contains("com.apple.Passwords") && s.first == "com.1password.1password")
    }
}
```

- [ ] **Step 2:** `swift test --filter "AppExclusionFilterTests|ConcealedTypeFilterTests|RecentAppsTests|ExclusionSeedsTests"` → compile errors.

- [ ] **Step 3: Implement**

`CaptureContext.swift`:
```swift
import AppKit

/// What the monitor knows about a pasteboard change before it reads any content.
public struct CaptureContext: Sendable, Equatable {
    /// Frontmost app when the change was noticed — the best attribution we have.
    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// Every app frontmost within the poll window, newest first, `sourceBundleID` included.
    /// Filters must treat all of them as possible sources (Critical Invariant 12).
    public var recentBundleIDs: [String]
    public init(sourceBundleID: String? = nil, sourceAppName: String? = nil, recentBundleIDs: [String] = []) {
        self.sourceBundleID = sourceBundleID; self.sourceAppName = sourceAppName; self.recentBundleIDs = recentBundleIDs
    }
}

/// Decides whether a pasteboard change may enter history, in two stages: `shouldRead` runs on
/// declared types and the pre-read context before any content is touched, so content is never
/// read when it won't be captured; `shouldCapture` runs after the read on the full candidate, the
/// union of pre- and post-read types, and a refreshed context. Filters run in order; any `false` wins.
public protocol CaptureFilter: Sendable {
    func shouldRead(types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool
    func shouldCapture(_ candidate: CaptureCandidate, types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool
}
```
`ConcealedTypeFilter.swift`: the existing struct moved verbatim (doc comment, `markers`, `isConcealed`), made `public` with `public init() {}`, methods taking the extra `context:` parameter and ignoring it.

`AppExclusionFilter.swift`:
```swift
import AppKit

/// Rejects changes whose source app — or any app frontmost within the poll window — is on the
/// user's exclusion list. Runs at stage 1 so an excluded app's bytes are never read.
public struct AppExclusionFilter: CaptureFilter {
    private let excluded: Set<String>
    public init(excludedBundleIDs: [String]) { excluded = Set(excludedBundleIDs.map { $0.lowercased() }) }
    public func isExcluded(_ bundleID: String?) -> Bool { bundleID.map { excluded.contains($0.lowercased()) } ?? false }
    private func rejects(_ context: CaptureContext) -> Bool {
        isExcluded(context.sourceBundleID) || context.recentBundleIDs.contains(where: isExcluded)
    }
    public func shouldRead(types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool { !rejects(context) }
    public func shouldCapture(_ candidate: CaptureCandidate, types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool { !rejects(context) }
}
```
`ExclusionSeeds.swift`: `public enum ExclusionSeeds { public static let passwordManagers: [String] = [ …the twelve ids from Global Constraints, in order… ] }` with a comment that the list is a default, user-editable in Settings → Privacy.

`RecentApps.swift`:
```swift
import Foundation

/// Pure windowing over frontmost-app activation entries. The app-side tracker feeds it.
public enum RecentApps {
    public struct Entry: Sendable, Equatable {
        public var bundleID: String
        public var appName: String
        public var activatedAt: Date
        public init(bundleID: String, appName: String, activatedAt: Date) { self.bundleID = bundleID; self.appName = appName; self.activatedAt = activatedAt }
    }

    /// Bundle ids of every app that was frontmost at some instant in `[now - window, now]`,
    /// newest first, de-duplicated. `entries` are in activation order (oldest first). The newest
    /// entry is always included; an older entry is included iff the entry that replaced it was
    /// activated inside the window (i.e. it was still frontmost when the window opened).
    public static func window(entries: [Entry], now: Date, window: TimeInterval) -> [String] {
        let cutoff = now.addingTimeInterval(-window)
        var out: [String] = []
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            // entries[i] stayed frontmost until entries[i+1] took over; if that hand-over happened
            // at or before the cutoff, entries[i] and everything older lie outside the window.
            if i + 1 < entries.count, entries[i + 1].activatedAt <= cutoff { break }
            let id = entries[i].bundleID
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Drops entries that stopped being frontmost more than `retention` ago, always keeping the current one.
    public static func trimmed(_ entries: [Entry], now: Date, retention: TimeInterval) -> [Entry] {
        let cutoff = now.addingTimeInterval(-retention)
        guard let last = entries.last else { return [] }
        var kept: [Entry] = [last]
        var i = entries.count - 2
        while i >= 0, entries[i + 1].activatedAt > cutoff { kept.insert(entries[i], at: 0); i -= 1 }
        return kept
    }
}
```
The tests are the contract for `window`: newest to oldest, include entry *i* iff it is the newest or `entries[i+1].activatedAt > cutoff`, stop at the first exclusion.

`PasteboardMonitor.swift`: delete the app-side `CaptureFilter` protocol and `ConcealedTypeFilter` struct (they now come from `PastefixAppCore`); change the two chain calls to `$0.shouldRead(types: types, context: CaptureContext())` and `$0.shouldCapture(candidate, types: finalTypes, context: CaptureContext())` with a `// Task 3 supplies the real context` comment. Leave the `NSWorkspace` sampling in `read` for now.

- [ ] **Step 4:** filter green; full `swift test` green; app build `xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"` → `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `feat(appcore): Capture filters in the package — CaptureContext, AppExclusionFilter, seeds, RecentApps; monitor adapted`.

---

### Task 2: Exclusion-list setting

**Files:** Modify `Sources/PastefixAppCore/SettingsStore.swift`; Test `Tests/PastefixAppCoreTests/SettingsStoreTests.swift` (append).

- [ ] **Step 1: Failing tests** (use the file's existing `withFreshDefaults` helper):
```swift
    @Test func exclusionsDefaultToSeedsAndEmptyStaysEmpty() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.historyExcludedBundleIDs == ExclusionSeeds.passwordManagers)
            s.historyExcludedBundleIDs = []
            #expect(SettingsStore(defaults: d).historyExcludedBundleIDs.isEmpty)
        }
    }
    @Test func addRemoveRestoreExclusions() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            s.historyExcludedBundleIDs = []
            s.addExcludedBundleID("  com.example.App ")
            s.addExcludedBundleID("COM.EXAMPLE.APP")
            s.addExcludedBundleID("")
            #expect(s.historyExcludedBundleIDs == ["com.example.App"])
            s.removeExcludedBundleID("com.example.app")
            #expect(s.historyExcludedBundleIDs.isEmpty)
            s.restoreDefaultExclusions()
            #expect(SettingsStore(defaults: d).historyExcludedBundleIDs == ExclusionSeeds.passwordManagers)
        }
    }
```
- [ ] **Step 2:** `swift test --filter SettingsStoreTests` → compile errors.
- [ ] **Step 3: Implement** in `SettingsStore`:
```swift
    @Published public var historyExcludedBundleIDs: [String] { didSet { Self.writeJSON(historyExcludedBundleIDs, to: defaults, key: Key.historyExcluded) } }
    // init:
    self.historyExcludedBundleIDs = Self.readJSON([String].self, from: defaults, key: Key.historyExcluded) ?? ExclusionSeeds.passwordManagers
    // Key: static let historyExcluded = "pastefix.historyExcludedBundleIDs"

    public func addExcludedBundleID(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !historyExcludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
        historyExcludedBundleIDs.append(id)
    }
    public func removeExcludedBundleID(_ id: String) {
        historyExcludedBundleIDs.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
    public func restoreDefaultExclusions() { historyExcludedBundleIDs = ExclusionSeeds.passwordManagers }
```
Check `readJSON` returns nil (not `[]`) for an absent key and decodes a stored `[]` as an empty array — the test covers both.
- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(appcore): historyExcludedBundleIDs setting with seeds, add/remove/restore`.

---

### Task 3: Tracker, monitor context, delegate wiring

**Files:** Create `Pastefix/Pastefix/FrontmostAppTracker.swift`; Modify `Pastefix/Pastefix/PasteboardMonitor.swift`, `Pastefix/Pastefix/PastefixApp.swift`.

- [ ] **Step 1: `FrontmostAppTracker.swift`**
```swift
import AppKit
import PastefixAppCore

/// Knows which apps were frontmost recently, from workspace activation notifications, so the
/// monitor can attribute a pasteboard change (and apply exclusions) BEFORE reading it — the
/// poll runs up to half a second after the copy, by which time the user may have switched apps.
@MainActor
final class FrontmostAppTracker {
    private var entries: [RecentApps.Entry] = []
    private var observer: NSObjectProtocol?
    private let retention: TimeInterval = 5

    init(workspace: NSWorkspace = .shared) {
        if let app = workspace.frontmostApplication { record(app, at: Date()) }
        observer = workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: workspace, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.record(app, at: Date()) }
        }
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    private func record(_ app: NSRunningApplication, at date: Date) {
        entries.append(.init(bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? app.bundleIdentifier ?? "?", activatedAt: date))
        entries = RecentApps.trimmed(entries, now: date, retention: retention)
    }

    /// Context for a change noticed now: the current app as source, plus everything frontmost within `window`.
    func context(window: TimeInterval, now: Date = Date()) -> CaptureContext {
        let recent = RecentApps.window(entries: entries, now: now, window: window).filter { !$0.isEmpty }
        let current = entries.last
        return CaptureContext(sourceBundleID: current?.bundleID.isEmpty == false ? current?.bundleID : nil,
                              sourceAppName: current?.appName, recentBundleIDs: recent)
    }
}
```
If `deinit` accessing `NSWorkspace.shared` is rejected under strict concurrency, store the notification center in a `nonisolated(unsafe) let` or drop the removal (the tracker lives for the process lifetime).

- [ ] **Step 2: `PasteboardMonitor`** — add `private let tracker: FrontmostAppTracker` and `private let windowSeconds: TimeInterval` to init (`windowSeconds: TimeInterval = 1.0`). In `tick`:
  - after sampling `types`: `let context = tracker.context(window: windowSeconds)`; stage 1 uses it;
  - after the changeCount re-check: `let refreshed = tracker.context(window: windowSeconds)`; stage 2 uses `refreshed`; then `candidate.sourceBundleID = refreshed.sourceBundleID; candidate.sourceAppName = refreshed.sourceAppName` (make `candidate` a `var`);
  - remove the `NSWorkspace.shared.frontmostApplication` block from `read`;
  - update the header comment to describe the context flow; remove the "Task 3 supplies" placeholders.

- [ ] **Step 3: `AppDelegate`** — `private lazy var frontmostTracker = FrontmostAppTracker()`; `updateMonitor(enabled:)` builds the monitor with
```swift
PasteboardMonitor(filters: [ConcealedTypeFilter(), AppExclusionFilter(excludedBundleIDs: settings.historyExcludedBundleIDs)],
                  maxImageBytes: history.limits.maxImageBytes, tracker: frontmostTracker) { … }
```
and a new sink: `settings.$historyExcludedBundleIDs.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuildMonitor() } }` where `rebuildMonitor()` stops and nils the current monitor and calls `updateMonitor(enabled: settings.historyEnabled)`. Make sure `updateMonitor` creates a new monitor when `pasteboardMonitor == nil` (it does) and that start() is idempotent (it is).

- [ ] **Step 4: Build** → `BUILD SUCCEEDED`, no new warnings. `swift test` unchanged.
- [ ] **Step 5: Commit** `feat(app): FrontmostAppTracker; CaptureContext in both monitor stages; exclusion filter wired and rebuilt on change`.

---

### Task 4: Privacy tab and menu-bar pause

**Files:** Modify `Pastefix/Pastefix/SettingsView.swift`, `Pastefix/Pastefix/PastefixApp.swift`.

- [ ] **Step 1: Menu bar** — in `PastefixApp`:
```swift
        MenuBarExtra("Pastefix", systemImage: delegate.settings.historyEnabled ? "doc.on.clipboard" : "pause.circle") {
            Button("Summon Pastefix") { delegate.summon() }
            Toggle("Clipboard History", isOn: Binding(get: { delegate.settings.historyEnabled }, set: { delegate.settings.historyEnabled = $0 }))
            SettingsLink { Text("Settings…") }.keyboardShortcut(",", modifiers: .command)
            …
```
The scene must re-evaluate when the setting changes: hold `@ObservedObject private var settings: SettingsStore` on a small `MenuBarLabel`/wrapper if `delegate.settings` alone doesn't trigger updates — simplest: `struct MenuBarMenu: View { @ObservedObject var settings: SettingsStore; … }` for the content and compute the icon from an `@ObservedObject` inside a `Label` view passed as the `label:` closure of `MenuBarExtra(content:label:)`.

- [ ] **Step 2: Privacy tab** — in `SettingsView`: add `privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }` after General; move the whole `Section("History")` (toggle, stepper, count line, Clear History button, caption, and the `.alert`) from `general` to `privacy`; add:
```swift
            Section("Excluded apps") {
                Text("Copies made in these apps are never read or remembered.").font(.caption).foregroundStyle(.secondary)
                List(selection: $selectedExclusion) {
                    ForEach(settings.historyExcludedBundleIDs, id: \.self) { id in
                        ExcludedAppRow(bundleID: id).tag(id)
                    }
                }
                .frame(minHeight: 120)
                HStack {
                    Button("Add App…") { addAppFromPanel() }
                    Button("Add Identifier…") { showIdentifierPrompt = true }
                        .popover(isPresented: $showIdentifierPrompt) {
                            VStack(alignment: .leading) {
                                Text("Bundle identifier").font(.caption)
                                TextField("com.example.app", text: $newIdentifier).frame(width: 260)
                                    .onSubmit { commitIdentifier() }
                                HStack { Spacer(); Button("Add") { commitIdentifier() }.keyboardShortcut(.defaultAction) }
                            }.padding()
                        }
                    Button("Remove") { if let s = selectedExclusion { settings.removeExcludedBundleID(s); selectedExclusion = nil } }
                        .disabled(selectedExclusion == nil)
                    Spacer()
                    Button("Restore Defaults") { settings.restoreDefaultExclusions() }
                }
                Text("Copies made by browser password extensions come from the browser, not the manager; those are skipped when the extension marks them concealed, which 1Password, Bitwarden and Apple do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```
with `@State private var selectedExclusion: String?`, `@State private var showIdentifierPrompt = false`, `@State private var newIdentifier = ""`, and:
```swift
    private func commitIdentifier() { settings.addExcludedBundleID(newIdentifier); newIdentifier = ""; showIdentifierPrompt = false }
    private func addAppFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var missing: [String] = []
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { settings.addExcludedBundleID(id) } else { missing.append(url.lastPathComponent) }
        }
        if !missing.isEmpty { noBundleIDNames = missing }   // @State [String]; drives an .alert("No bundle identifier") listing them
    }
```
`ExcludedAppRow`:
```swift
struct ExcludedAppRow: View {
    let bundleID: String
    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.flatMap { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                Text(url == nil ? "\(bundleID) · not installed" : bundleID).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
```
Keep the window at 460×400; the Form scrolls.

- [ ] **Step 3: Build** → `BUILD SUCCEEDED`, no new warnings.
- [ ] **Step 4: Commit** `feat(app): Privacy tab with history and excluded apps; menu-bar Clipboard History toggle and pause glyph`.

---

### Task 5: Documentation

**Files:** `README.md`, `AGENTS.md`, `docs/specs/2026-09-21-pastefix-v2-clipboard-history.md`, this plan's banner.

- [ ] README: in "Clipboard history", add an "Excluded apps" paragraph (Settings → Privacy; seeded with common password managers; add from Applications or by identifier; the browser-extension caveat) and the menu-bar "Clipboard History" toggle with the pause glyph; Settings list: General loses History, Privacy tab added.
- [ ] AGENTS.md: layout (`Capture/`, `FrontmostAppTracker.swift`); Critical Invariant 12 amended verbatim per Global Constraints; Patterns note: "filters get a `CaptureContext` built before the read and refreshed after it; the tracker, not `frontmostApplication`, is the source of truth"; status row Plan 7 (🟡 in progress, branch); no "bitten us" entries (controller adds after review).
- [ ] Plan 6 spec: under "Open questions", mark the #10 item resolved by this spec.
- [ ] Banner of this plan → 🟡 IN PROGRESS.
- [ ] Commit `docs: sensitive-app exclusion — README, AGENTS invariant 12 amendment, Plan 6 cross-reference`.

---

### Task 6: Automated app pass (controller) and finish

- [ ] Build Debug to `/tmp/pastefix-dd`; quit any Pastefix; remove the test history dir afterwards.
- [ ] `defaults write scromp.net.Pastefix pastefix.historyExcludedBundleIDs -string '["com.googlecode.iterm2"]'` → relaunch → copy from iTerm2 → **not** recorded; delete the key → relaunch → recorded (source `iTerm2`).
- [ ] Concealed and legacy markers still skipped; de-dup and ⌘⇧V/⌘↵ still work.
- [ ] Capture toggle via `defaults` → icon glyph (visual) and overlay empty state.
- [ ] Visual: Privacy tab layout.
- [ ] Final whole-branch review, one fix wave, AGENTS "bitten us", push, PR closing #10, `git checkout main`.

---

## Self-review

- **Spec coverage:** tracker + pre-read context + refresh (T3); stage-1 exclusion, case-insensitive, recents fail-closed (T1); seeds and list semantics (T1, T2); Privacy tab with icon/name/not-installed, add from panel, add by id, remove, restore, caption (T4); menu toggle + glyph (T4); docs + invariant (T5); automated pass (T6).
- **Type consistency:** `CaptureContext(sourceBundleID:sourceAppName:recentBundleIDs:)`, `CaptureFilter.shouldRead(types:context:)` / `shouldCapture(_:types:context:)`, `AppExclusionFilter(excludedBundleIDs:)`, `RecentApps.Entry/window/trimmed`, `SettingsStore.historyExcludedBundleIDs/addExcludedBundleID/removeExcludedBundleID/restoreDefaultExclusions`, `FrontmostAppTracker.context(window:)` — used identically across tasks.
- **Placeholders:** none; the one "if strict concurrency rejects X" note names the fallback.
