# Pastefix v2 Settings & Preferences (Plan 2b) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; async/AppKit concurrency → `swift-concurrency-pro`; SwiftUI → `swiftui-pro`. Package tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

**Goal:** Make the Pastefix app configurable: a Settings window (wrap width, auto-hide, scripts dir, per-transform enable/reorder), a rebindable global hotkey, live reload of user scripts, and auto-hide-on-blur.

**Architecture:** Persisted settings and the pure per-transform override logic live in `PastefixAppCore` (unit-tested via `swift test`). The app target consumes them: a SwiftUI `Settings` scene, the `KeyboardShortcuts` package for the rebindable hotkey (replacing the fixed Carbon `GlobalHotkey`), a `ScriptWatcher` wired to reload the palette on script changes, and `PanelController.onResignKey` wired to auto-hide.

**Tech Stack:** Swift 6, SwiftPM (`PastefixAppCore`) + Xcode app target, SwiftUI `Settings`/`SettingsLink`, `KeyboardShortcuts` (Sindre Sorhus, remote SPM dep — app target only), `PastefixCore.ScriptWatcher`, `UserDefaults`. Tests: Swift Testing.

## Global Constraints

- **Engine untouched.** `PastefixCore` is not modified in this plan. Per-transform enable/order are applied as a **post-load override in the app layer**, not by rewriting user script files or changing the registry. A script's `# pastefix: enabled = false` header is still a hard "don't load" (edit the file); Settings enable/reorder operate on what `load()` returns.
- **New dependency is app-target only.** `KeyboardShortcuts` is added to the `Pastefix` Xcode target. `PastefixCore` and `PastefixAppCore` remain dependency-free of third-party packages (AppCore may `import KeyboardShortcuts`? NO — AppCore stays third-party-free; the `KeyboardShortcuts.Name` definition lives in the app target).
- **App stays NON-SANDBOXED** (`ENABLE_APP_SANDBOX = NO`) — do not let any Settings/entitlements work re-enable it (invariant 9).
- **Testable logic in `PastefixAppCore`, glue in the Xcode target** (invariant: the testability rule). `SettingsStore` and the override application are pure/testable; SwiftUI views, the recorder, and watcher/panel wiring are glue.
- **Paths:** Xcode project at `Pastefix/Pastefix.xcodeproj`; app sources at `Pastefix/Pastefix/`. Xcode 16 synchronized groups auto-add new `.swift` files. Do NOT hand-edit `project.pbxproj` except a human/controller adding a package product.
- **Defaults:** wrap width `400`; auto-hide-on-blur `true`; scripts dir `~/.config/pastefix/scripts`; hotkey `⌘⇧C`. UserDefaults keys are namespaced `pastefix.`.
- **Build/verify:** package logic → `swift test`; app → `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug`. Manual UX for runtime behavior (Task 10).

---

## File Structure

```
Sources/PastefixAppCore/
  SettingsStore.swift          NEW  UserDefaults-backed settings (ObservableObject)
  TransformOverrides.swift     NEW  pure filter+order application over [any Transformer]
Tests/PastefixAppCoreTests/
  SettingsStoreTests.swift     NEW
  TransformOverridesTests.swift NEW

Pastefix/Pastefix/
  HotkeyName.swift             NEW  KeyboardShortcuts.Name.summonPastefix (default ⌘⇧C)
  GlobalHotkey.swift           DELETE  (replaced by KeyboardShortcuts)
  AppModel.swift               MODIFY  reactive transformers; reload(); settings-driven config
  PastefixApp.swift            MODIFY  Settings scene; SettingsLink; hotkey via KeyboardShortcuts;
                                        ScriptWatcher + auto-hide wiring in AppDelegate
  SettingsView.swift           NEW  General / Shortcut / Transforms tabs
  Pastefix.xcodeproj           MODIFY  add KeyboardShortcuts package product (Task 3, human)
```

---

## Task 1: `SettingsStore` (PastefixAppCore, TDD)

**Files:**
- Create: `Sources/PastefixAppCore/SettingsStore.swift`
- Test: `Tests/PastefixAppCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `@MainActor final class SettingsStore: ObservableObject` backed by an injected `UserDefaults` (`init(defaults: UserDefaults = .standard)`), with published, write-through properties:
  - `var wrapWidth: Int` (default 400), `var autoHideOnBlur: Bool` (default true), `var scriptsDirectoryPath: String` (default the expanded `~/.config/pastefix/scripts`).
  - `var transformEnabled: [String: Bool]` and `var transformOrder: [String: Int]` (per-transformer-id overrides; empty by default), persisted as JSON.
  - `var scriptsDirectoryURL: URL` (computed from `scriptsDirectoryPath`).
  Each stored property reads its initial value from `defaults` in `init` and writes back on `didSet` under a namespaced key (`pastefix.wrapWidth`, `pastefix.autoHideOnBlur`, `pastefix.scriptsDirectoryPath`, `pastefix.transformEnabled`, `pastefix.transformOrder`).

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixAppCoreTests/SettingsStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixAppCore

@MainActor
@Suite struct SettingsStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "pastefix.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsWhenEmpty() {
        let s = SettingsStore(defaults: freshDefaults())
        #expect(s.wrapWidth == 400)
        #expect(s.autoHideOnBlur == true)
        #expect(s.scriptsDirectoryPath.hasSuffix("/.config/pastefix/scripts"))
        #expect(s.transformEnabled.isEmpty)
        #expect(s.transformOrder.isEmpty)
    }

    @Test func writesPersistAndReload() {
        let d = freshDefaults()
        let s = SettingsStore(defaults: d)
        s.wrapWidth = 72
        s.autoHideOnBlur = false
        s.transformEnabled = ["shell:foo.sh": false]
        s.transformOrder = ["builtin.whitespace": 5]

        // A second store over the same defaults sees the persisted values.
        let s2 = SettingsStore(defaults: d)
        #expect(s2.wrapWidth == 72)
        #expect(s2.autoHideOnBlur == false)
        #expect(s2.transformEnabled["shell:foo.sh"] == false)
        #expect(s2.transformOrder["builtin.whitespace"] == 5)
    }

    @Test func scriptsDirectoryURLMatchesPath() {
        let s = SettingsStore(defaults: freshDefaults())
        s.scriptsDirectoryPath = "/tmp/pfx-scripts"
        #expect(s.scriptsDirectoryURL == URL(fileURLWithPath: "/tmp/pfx-scripts", isDirectory: true))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SettingsStoreTests`
Expected: FAIL — `SettingsStore` undefined.

- [ ] **Step 3: Implement**

Create `Sources/PastefixAppCore/SettingsStore.swift`:

```swift
import Foundation
import Combine

/// UserDefaults-backed application settings. Published for SwiftUI binding;
/// each property writes through to `defaults` on mutation.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var wrapWidth: Int { didSet { defaults.set(wrapWidth, forKey: Key.wrapWidth) } }
    @Published public var autoHideOnBlur: Bool { didSet { defaults.set(autoHideOnBlur, forKey: Key.autoHide) } }
    @Published public var scriptsDirectoryPath: String { didSet { defaults.set(scriptsDirectoryPath, forKey: Key.scriptsDir) } }
    @Published public var transformEnabled: [String: Bool] { didSet { Self.writeJSON(transformEnabled, to: defaults, key: Key.enabled) } }
    @Published public var transformOrder: [String: Int] { didSet { Self.writeJSON(transformOrder, to: defaults, key: Key.order) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wrapWidth = (defaults.object(forKey: Key.wrapWidth) as? Int) ?? 400
        self.autoHideOnBlur = (defaults.object(forKey: Key.autoHide) as? Bool) ?? true
        self.scriptsDirectoryPath = (defaults.string(forKey: Key.scriptsDir)) ?? Self.defaultScriptsPath
        self.transformEnabled = Self.readJSON([String: Bool].self, from: defaults, key: Key.enabled) ?? [:]
        self.transformOrder = Self.readJSON([String: Int].self, from: defaults, key: Key.order) ?? [:]
    }

    public var scriptsDirectoryURL: URL {
        URL(fileURLWithPath: scriptsDirectoryPath, isDirectory: true)
    }

    static var defaultScriptsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pastefix/scripts", isDirectory: true).path
    }

    private enum Key {
        static let wrapWidth = "pastefix.wrapWidth"
        static let autoHide = "pastefix.autoHideOnBlur"
        static let scriptsDir = "pastefix.scriptsDirectoryPath"
        static let enabled = "pastefix.transformEnabled"
        static let order = "pastefix.transformOrder"
    }

    private static func writeJSON<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SettingsStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/SettingsStore.swift Tests/PastefixAppCoreTests/SettingsStoreTests.swift
git commit -m "feat(appcore): add UserDefaults-backed SettingsStore"
```

---

## Task 2: `TransformOverrides` — pure enable/reorder application (PastefixAppCore, TDD)

**Files:**
- Create: `Sources/PastefixAppCore/TransformOverrides.swift`
- Test: `Tests/PastefixAppCoreTests/TransformOverridesTests.swift`

**Interfaces:**
- Consumes: `PastefixCore.Transformer` (has `id`, `name`).
- Produces: `enum TransformOverrides` with
  `static func apply(to loaded: [any Transformer], enabled: [String: Bool], order: [String: Int]) -> [any Transformer]`.
  Rules: an entry is **kept** unless `enabled[id] == false` (missing → kept). The kept entries are sorted by `order[id]` when present, otherwise by their **original index** in `loaded` (so unspecified items hold their load-order position); ties broken by original index. Stable and deterministic.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixAppCoreTests/TransformOverridesTests.swift`:

```swift
import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

private struct StubTransformer: Transformer {
    let id: String
    let name: String
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite struct TransformOverridesTests {
    private let loaded: [any Transformer] = [
        StubTransformer(id: "a", name: "A"),
        StubTransformer(id: "b", name: "B"),
        StubTransformer(id: "c", name: "C"),
    ]

    @Test func noOverridesKeepsLoadOrder() {
        let out = TransformOverrides.apply(to: loaded, enabled: [:], order: [:])
        #expect(out.map(\.id) == ["a", "b", "c"])
    }

    @Test func disabledEntryIsRemoved() {
        let out = TransformOverrides.apply(to: loaded, enabled: ["b": false], order: [:])
        #expect(out.map(\.id) == ["a", "c"])
    }

    @Test func missingEnabledMeansKept() {
        let out = TransformOverrides.apply(to: loaded, enabled: ["a": true], order: [:])
        #expect(out.map(\.id) == ["a", "b", "c"])
    }

    @Test func explicitOrderOverridesLoadOrderElsePositionHeld() {
        // c gets order 0 (front); a,b have no order → hold their load positions after.
        let out = TransformOverrides.apply(to: loaded, enabled: [:], order: ["c": 0])
        #expect(out.first?.id == "c")
    }

    @Test func fullReorder() {
        let out = TransformOverrides.apply(to: loaded, enabled: [:], order: ["a": 30, "b": 20, "c": 10])
        #expect(out.map(\.id) == ["c", "b", "a"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TransformOverridesTests`
Expected: FAIL — `TransformOverrides` undefined.

- [ ] **Step 3: Implement**

Create `Sources/PastefixAppCore/TransformOverrides.swift`:

```swift
import Foundation
import PastefixCore

/// Applies the user's app-local enable/reorder preferences on top of the
/// registry's loaded transformers. Pure; does not touch disk or the engine.
public enum TransformOverrides {
    public static func apply(
        to loaded: [any Transformer],
        enabled: [String: Bool],
        order: [String: Int]
    ) -> [any Transformer] {
        let kept = loaded.enumerated().filter { enabled[$0.element.id] != false }
        // Sort key: explicit order if present, else a large sentinel; ties by load index.
        let sentinel = Int.max
        return kept
            .sorted { lhs, rhs in
                let lo = order[lhs.element.id] ?? sentinel
                let ro = order[rhs.element.id] ?? sentinel
                if lo != ro { return lo < ro }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TransformOverridesTests`
Expected: PASS (5 tests).

> Note on `explicitOrderOverridesLoadOrderElsePositionHeld`: with `order = ["c": 0]`, c sorts to 0 while a,b use the `sentinel` and fall back to load index (0,1). So order is c, a, b — `out.first == "c"` holds.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/TransformOverrides.swift Tests/PastefixAppCoreTests/TransformOverridesTests.swift
git commit -m "feat(appcore): add pure transform enable/reorder override application"
```

---

## Task 3: USER adds the `KeyboardShortcuts` package dependency (manual prerequisite)

**This task is performed by the human.** The controller must not dispatch a subagent — present the steps, wait, then verify.

**Steps for the user (in Xcode):**

1. Open `Pastefix/Pastefix.xcodeproj`.
2. **File → Add Package Dependencies…**
3. In the search/URL field paste: `https://github.com/sindresorhus/KeyboardShortcuts`
4. Dependency Rule: **Up to Next Major Version** (accept the default). Click **Add Package**.
5. When prompted to choose the target for the `KeyboardShortcuts` library product, add it to the **Pastefix** app target. Click **Add Package**.
6. Build once (⌘B) to confirm resolution, then commit:
   ```bash
   git add Pastefix/Pastefix.xcodeproj Pastefix/Pastefix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
   git commit -m "chore(app): add KeyboardShortcuts package dependency"
   ```
   (If `Package.resolved` is at a different path under the project, add whatever `git status` shows as new/modified under `Pastefix.xcodeproj`.)

- [ ] **Controller verification (before dispatching Task 4):**

Run:
```bash
xcodebuild -list -project Pastefix/Pastefix.xcodeproj 2>&1 | grep -i pastefix
grep -c "KeyboardShortcuts" Pastefix/Pastefix.xcodeproj/project.pbxproj
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"
```
Expected: the `KeyboardShortcuts` references appear in the pbxproj and the build succeeds. If not, return to the user with the specific gap.

---

## Task 4: Rebindable hotkey via KeyboardShortcuts (app, build-verify)

**Files:**
- Create: `Pastefix/Pastefix/HotkeyName.swift`
- Modify: `Pastefix/Pastefix/PastefixApp.swift` (AppDelegate hotkey wiring)
- Delete: `Pastefix/Pastefix/GlobalHotkey.swift`

**Interfaces:**
- Consumes: `KeyboardShortcuts` (Task 3), `AppModel` (existing, unchanged here).
- Produces: `extension KeyboardShortcuts.Name { static let summonPastefix }` with default `⌘⇧C`; the AppDelegate registers a listener via `KeyboardShortcuts.onKeyUp(for: .summonPastefix)` calling `summon()`. `GlobalHotkey` is removed.

- [ ] **Step 1: Define the shortcut name**

Create `Pastefix/Pastefix/HotkeyName.swift`:

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global summon hotkey. Default ⌘⇧C; rebindable in Settings.
    static let summonPastefix = Self(
        "summonPastefix",
        default: .init(.c, modifiers: [.command, .shift])
    )
}
```

- [ ] **Step 2: Replace the Carbon hotkey in the AppDelegate**

In `Pastefix/Pastefix/PastefixApp.swift`, remove the `GlobalHotkey` property and its creation in `applicationDidFinishLaunching`, and register the KeyboardShortcuts listener instead. The delegate's hotkey setup becomes:

```swift
import SwiftUI
import AppKit
import KeyboardShortcuts

// ... (AppDelegate keeps: model, panel; drop the `hotkey` property)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostingView = NSHostingView(rootView: PanelView(model: model))
        let panel = PanelController(rootView: hostingView)
        self.panel = panel

        model.onEndSession = { [weak self] in self?.panel?.hide() }

        // Global summon hotkey (default ⌘⇧C, rebindable in Settings).
        KeyboardShortcuts.onKeyUp(for: .summonPastefix) { [weak self] in
            self?.summon()
        }
    }
```

Delete the `private var hotkey: GlobalHotkey?` line and any `hotkey.register()` / stored-hotkey code. Keep `summon()` and `model` exactly as they are.

- [ ] **Step 3: Delete the Carbon implementation**

```bash
git rm Pastefix/Pastefix/GlobalHotkey.swift
```

- [ ] **Step 4: Build**

Run: `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"`
Expected: `** BUILD SUCCEEDED **`. Confirm there is no remaining reference to `GlobalHotkey`.

- [ ] **Step 5: Commit**

```bash
git add Pastefix/Pastefix/HotkeyName.swift Pastefix/Pastefix/PastefixApp.swift
git rm Pastefix/Pastefix/GlobalHotkey.swift
git commit -m "feat(app): rebindable summon hotkey via KeyboardShortcuts (replaces Carbon)"
```

---

## Task 5: `AppModel` — reactive transformers + settings-driven reload (app, build-verify)

**Files:**
- Modify: `Pastefix/Pastefix/AppModel.swift`

**Interfaces:**
- Consumes: `SettingsStore`, `TransformOverrides` (Tasks 1–2); existing `TransformerRegistry`, `RegistryConfig`, `TransformCoordinator`, `ClipboardBridge`.
- Produces: `AppModel` now takes `init(settings: SettingsStore)`; `transformers` becomes `@Published private(set) var transformers: [any Transformer]`; a `func reload()` rebuilds the registry from `settings` (scriptsDir + wrapWidth) and applies overrides; `enabledTransformers()` filters the (already override-applied) `transformers` by rich-gating only. A `settings` reference is held for reload and auto-hide.

- [ ] **Step 1: Rewrite AppModel to consume settings**

Replace `Pastefix/Pastefix/AppModel.swift` with:

```swift
import Foundation
import AppKit
import Combine
import PastefixCore
import PastefixAppCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var document: PasteDocument?
    @Published var errorMessage: String?
    @Published private(set) var isApplying = false
    @Published private(set) var transformers: [any Transformer] = []

    let settings: SettingsStore
    var onEndSession: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        reload()
    }

    /// Rebuild the transformer list from current settings (scripts dir + wrap
    /// width) and apply the user's enable/reorder overrides. Safe to call any
    /// time (e.g. on a script-directory change or a settings edit).
    func reload() {
        let config = RegistryConfig(
            scriptsDirectory: settings.scriptsDirectoryURL,
            wrapWidth: settings.wrapWidth
        )
        let loaded = TransformerRegistry(config: config).load()
        transformers = TransformOverrides.apply(
            to: loaded,
            enabled: settings.transformEnabled,
            order: settings.transformOrder
        )
    }

    func summon() {
        errorMessage = nil
        document = PasteDocument(origin: ClipboardBridge.snapshot())
    }

    func enabledTransformers() -> [any Transformer] {
        guard let document else { return [] }
        return transformers.filter { TransformCoordinator.isEnabled($0, for: document) }
    }

    func apply(_ transformer: any Transformer) {
        guard let current = document, !isApplying else { return }
        isApplying = true
        Task {
            let (updated, outcome) = await TransformCoordinator.apply(transformer, to: current)
            self.document = updated
            switch outcome {
            case .applied, .unchanged: self.errorMessage = nil
            case .failed(let message): self.errorMessage = message
            }
            self.isApplying = false
        }
    }

    func setWorking(_ text: String) {
        guard var doc = document else { return }
        doc.setWorking(text)
        document = doc
    }

    func undo() { guard var doc = document else { return }; doc.undo(); document = doc }
    func redo() { guard var doc = document else { return }; doc.redo(); document = doc }

    func refresh() {
        guard var doc = document else { return }
        doc.refresh(origin: ClipboardBridge.snapshot())
        document = doc
        errorMessage = nil
    }

    func save() {
        if let text = document?.working { ClipboardBridge.writePlain(text) }
        endSession()
    }

    func cancel() { endSession() }

    private func endSession() {
        document = nil
        errorMessage = nil
        onEndSession?()
    }
}
```

- [ ] **Step 2: Update the AppDelegate to construct AppModel with settings**

In `Pastefix/Pastefix/PastefixApp.swift`, the AppDelegate must own a `SettingsStore` and pass it to `AppModel`. Change the model/settings properties:

```swift
    private(set) var settings = SettingsStore()
    private(set) lazy var model = AppModel(settings: settings)
```

(Keep the `import PastefixAppCore` at the top of the file. The `lazy` lets `model` use `settings` at first access.)

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"`
Expected: `** BUILD SUCCEEDED **`. (`PanelView` still binds to the same `AppModel` API it used before — `enabledTransformers()`, `apply`, etc. — so it is unaffected.)

- [ ] **Step 4: Commit**

```bash
git add Pastefix/Pastefix/AppModel.swift Pastefix/Pastefix/PastefixApp.swift
git commit -m "feat(app): drive transformers from settings with reload + overrides"
```

---

## Task 6: Live script reload via `ScriptWatcher` (app, build-verify)

**Files:**
- Modify: `Pastefix/Pastefix/PastefixApp.swift` (AppDelegate)

**Interfaces:**
- Consumes: `PastefixCore.ScriptWatcher` (`init(directory:debounce:onChange:)`, `start()`, `stop()`), `AppModel.reload()`, `SettingsStore.scriptsDirectoryURL`.
- Produces: the AppDelegate owns a `ScriptWatcher` that calls `model.reload()` (on the main actor) when the scripts directory changes.

- [ ] **Step 1: Add the watcher to the AppDelegate**

In `applicationDidFinishLaunching` (after the model/panel/hotkey setup), start a watcher and store it. Add a stored property `private var scriptWatcher: PastefixCore.ScriptWatcher?` and:

```swift
        // Live-reload the palette when the user's scripts directory changes.
        let dir = settings.scriptsDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let watcher = ScriptWatcher(directory: dir) { [weak self] in
            // onChange is delivered on the main queue by ScriptWatcher's debouncer.
            MainActor.assumeIsolated { self?.model.reload() }
        }
        watcher.start()
        self.scriptWatcher = watcher
```

Add `import PastefixCore` to the file if not already present.

> Note: `ScriptWatcher`'s debouncer dispatches `onChange` on `.main`; `MainActor.assumeIsolated` lets us call the `@MainActor` `model.reload()` without an await. If the compiler rejects `assumeIsolated` here, wrap in `Task { @MainActor in self?.model.reload() }` instead — either is acceptable as long as `reload()` runs on the main actor.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Pastefix/Pastefix/PastefixApp.swift
git commit -m "feat(app): live-reload transform palette on scripts-directory changes"
```

---

## Task 7: Auto-hide-on-blur (app, build-verify)

**Files:**
- Modify: `Pastefix/Pastefix/PastefixApp.swift` (AppDelegate wires `panel.onResignKey`)

**Interfaces:**
- Consumes: `PanelController.onResignKey` (existing stub), `SettingsStore.autoHideOnBlur`, `AppModel.cancel()`.
- Produces: when the panel loses key focus AND `settings.autoHideOnBlur` is true AND a session is active, the panel auto-hides (Cancel-equivalent: clipboard untouched, session ends).

- [ ] **Step 1: Wire onResignKey after creating the panel**

In `applicationDidFinishLaunching`, after `self.panel = panel` and before/after the hotkey wiring, add:

```swift
        panel.onResignKey = { [weak self] in
            guard let self, self.settings.autoHideOnBlur, self.model.document != nil else { return }
            self.model.cancel()   // ends session; onEndSession hides the panel
        }
```

(Guarding on `model.document != nil` prevents a spurious hide when the panel isn't presenting a session.)

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Pastefix/Pastefix/PastefixApp.swift
git commit -m "feat(app): auto-hide the panel on blur when enabled in settings"
```

---

## Task 8: Settings UI (app, build-verify)

**Files:**
- Create: `Pastefix/Pastefix/SettingsView.swift`
- Modify: `Pastefix/Pastefix/PastefixApp.swift` (add `Settings` scene + `SettingsLink` menu item)

**Interfaces:**
- Consumes: `SettingsStore` (Task 1), `AppModel` (Task 5, for the transform list + `reload()`), `KeyboardShortcuts.Recorder` + `.summonPastefix` (Tasks 3–4).
- Produces: a `SettingsView` with three tabs (General, Shortcut, Transforms); the app's `Settings` scene hosts it; the MenuBarExtra gets a `SettingsLink` "Settings…" item.

- [ ] **Step 1: Implement `SettingsView`**

Create `Pastefix/Pastefix/SettingsView.swift`:

```swift
import SwiftUI
import KeyboardShortcuts
import PastefixAppCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shortcut.tabItem { Label("Shortcut", systemImage: "keyboard") }
            transforms.tabItem { Label("Transforms", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 460, height: 340)
    }

    private var general: some View {
        Form {
            Stepper("Wrap width: \(settings.wrapWidth)", value: $settings.wrapWidth, in: 20...2000, step: 4)
                .onChange(of: settings.wrapWidth) { _, _ in model.reload() }
            Toggle("Hide panel when it loses focus", isOn: $settings.autoHideOnBlur)
            LabeledContent("Scripts folder") {
                HStack {
                    Text(settings.scriptsDirectoryPath).truncationMode(.middle).lineLimit(1)
                    Button("Choose…") { chooseScriptsDir() }
                }
            }
        }
        .padding()
    }

    private var shortcut: some View {
        Form {
            KeyboardShortcuts.Recorder("Summon Pastefix:", name: .summonPastefix)
            Text("Global hotkey to summon the panel from any app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var transforms: some View {
        VStack(alignment: .leading) {
            Text("Enable, disable, and reorder transforms. Drag to reorder.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.transformers, id: \.id) { t in
                    Toggle(isOn: enabledBinding(for: t.id)) { Text(t.name) }
                }
                .onMove(perform: moveTransforms)
            }
        }
        .padding()
    }

    private func enabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { settings.transformEnabled[id] ?? true },
            set: { settings.transformEnabled[id] = $0; model.reload() }
        )
    }

    private func moveTransforms(from source: IndexSet, to destination: Int) {
        var ids = model.transformers.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        var order: [String: Int] = [:]
        for (index, id) in ids.enumerated() { order[id] = index * 10 }
        settings.transformOrder = order
        model.reload()
    }

    private func chooseScriptsDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.scriptsDirectoryPath = url.path
            model.reload()
        }
    }
}
```

(`NSOpenPanel` requires AppKit; `import SwiftUI` re-exports it on macOS, but add `import AppKit` if the build complains.)

- [ ] **Step 2: Add the Settings scene and menu item**

In `Pastefix/Pastefix/PastefixApp.swift`, add a `Settings` scene to the `body` and a `SettingsLink` in the `MenuBarExtra`. The scene body becomes:

```swift
    var body: some Scene {
        MenuBarExtra("Pastefix", systemImage: "doc.on.clipboard") {
            Button("Summon Pastefix") { delegate.summon() }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView(settings: delegate.settings, model: delegate.model)
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Pastefix/Pastefix/SettingsView.swift Pastefix/Pastefix/PastefixApp.swift
git commit -m "feat(app): Settings window (general, shortcut recorder, transform list)"
```

---

## Task 9: Docs + full verification (docs, verify)

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:** none.

- [ ] **Step 1: Full package suite**

Run: `swift test`
Expected: PASS — the existing suites plus `SettingsStoreTests` (3) and `TransformOverridesTests` (5). Report the total.

- [ ] **Step 2: App build**

Run: `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Update docs**

- `README.md`: add a "Settings (Plan 2b)" note — the Settings window (wrap width, auto-hide, scripts folder, per-transform enable/reorder), the rebindable ⌘⇧C hotkey, and live script reload. Note Sparkle auto-updates are still forthcoming.
- `AGENTS.md`: update "Still forthcoming (Plan 2b…)" — remove the items now shipped (Settings, rebindable hotkey, live reload, auto-hide, configurable wrap width), leaving Sparkle. Add `KeyboardShortcuts` as the app target's one third-party dependency in the layout/what-this-is notes. Note that `GlobalHotkey.swift` (Carbon) was replaced by KeyboardShortcuts, and update the "things that bit us" Carbon entry to note it's historical (the file is gone).

- [ ] **Step 4: Commit**

```bash
git add README.md AGENTS.md
git commit -m "docs: document Plan 2b settings, hotkey, and live reload"
```

---

## Task 10: USER manual UX verification (manual)

**This task is performed by the human.** Present the checklist; record results; do not dispatch a subagent.

Launch: `Pastefix/launch.sh`.

- [ ] **Step 1: Settings opens** — from the menu-bar icon choose **Settings…** (or ⌘,). The window opens with General / Shortcut / Transforms tabs.
- [ ] **Step 2: Wrap width** — change **Wrap width** to a small number (e.g. 20). Summon (⌘⇧C), paste a long line, apply **Wrap & Reflow** → it wraps at the new width. (Confirms settings → registry config.)
- [ ] **Step 3: Rebind hotkey** — in **Shortcut**, record a new shortcut (e.g. ⌥⌘V). Confirm the new combo summons the panel and the old ⌘⇧C no longer does.
- [ ] **Step 4: Transforms enable/reorder** — in **Transforms**, disable one (e.g. Whitespace Cleanup) → it disappears from the palette on next summon. Drag to reorder → the palette order changes.
- [ ] **Step 5: Live reload** — with the app running, add an executable script to your scripts folder (`~/.config/pastefix/scripts/rev.sh` = `#!/bin/sh` / `# pastefix: name = Reverse` / `rev`). Within ~1s, summon → **Reverse** appears **without relaunch**.
- [ ] **Step 6: Auto-hide** — with "Hide panel when it loses focus" ON, summon the panel then click another app → the panel hides, clipboard unchanged. Toggle it OFF → summon → clicking away leaves the panel up.
- [ ] **Step 7: Persistence** — quit and relaunch; confirm your wrap width, hotkey, and transform tweaks survived.

Report any failing step; those become fix-loop findings.

---

## Self-Review

**Spec coverage** (against `docs/specs/2026-08-11-pastefix-v2-foundation-pipeline.md`, Settings section, and the 2b scope):

- Settings scene persisted to `UserDefaults` → Tasks 1, 8. ✓
- Global hotkey (rebindable, KeyboardShortcuts recorder, default ⌘⇧C) → Tasks 3, 4, 8. ✓
- Default wrap column width, configurable → Tasks 1, 5, 8. ✓
- Auto-hide-on-blur toggle → Tasks 1, 7, 8. ✓
- Per-transform enabled + order in one list → Tasks 2, 8 (applied in 5). ✓
- Scripts directory path (override) → Tasks 1, 8. ✓
- Live script reload via `ScriptWatcher` → Task 6. ✓
- **Source-of-truth deviation from spec (intentional, flagged):** the spec said script enable/order lives in magic-comment headers and built-ins in UserDefaults. This plan puts ALL app-local enable/order in `UserDefaults` overrides applied post-load, and never rewrites user script files. The header remains the on-disk default (`enabled=false` = hard skip). Rationale: an app must not silently rewrite a user's files. **Deferred to a later increment (correctly out of scope):** Sparkle auto-updates (needs appcast host + signing keys). Selection-scoped transforms; frontmost-app auto-paste.

**Placeholder scan:** no TBD/TODO; every code and test step has real content. Task 6's `assumeIsolated` fallback and Task 8's `import AppKit` note are concrete conditional instructions, not vague hand-waves.

**Type consistency:** `SettingsStore` (`wrapWidth`/`autoHideOnBlur`/`scriptsDirectoryPath`/`scriptsDirectoryURL`/`transformEnabled`/`transformOrder`, `init(defaults:)`); `TransformOverrides.apply(to:enabled:order:)`; `AppModel(settings:)` with published `transformers` + `reload()` + `settings`; `KeyboardShortcuts.Name.summonPastefix`; `PanelController.onResignKey`; `ScriptWatcher(directory:debounce:onChange:)`/`start()` — used consistently across Tasks 1–8. AppModel's public surface consumed by `PanelView` (`enabledTransformers()`, `apply`, `undo/redo/refresh/save/cancel`, `document`, `errorMessage`, `isApplying`) is unchanged, so Task 5's rewrite doesn't break the 2a UI.

**Verification honesty:** Tasks 1–2 are `swift test` TDD. Tasks 4–8 gate on `xcodebuild build` (subagents cannot exercise a global hotkey, the recorder, FSEvents timing, or blur). Tasks 3 and 10 are human-performed; the controller verifies Task 3's package link (build + pbxproj) and records Task 10's checklist before completing.
