# Pastefix v2 App Core (Plan 2a) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** when writing tests, invoke `swift-testing-pro`; for async/AppKit concurrency, invoke `swift-concurrency-pro`; for SwiftUI views, `swiftui-pro`. Package tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

**Goal:** Build the functional core of the Pastefix v2 menu-bar app: a global hotkey summons a floating panel that loads the clipboard, applies transforms from `PastefixCore` (click-to-apply, stacked with undo), and writes the result back on Save.

**Architecture:** Pure model (`ClipboardSnapshot`, `PasteDocument`, `TransformCoordinator`) lives in a new SwiftPM library target `PastefixAppCore` and is fully unit-tested via `swift test`. The Xcode app target `Pastefix` (SwiftUI `MenuBarExtra`, `LSUIElement`) holds only UI + system glue (Carbon global hotkey, `NSPanel`, `NSPasteboard` bridge, SwiftUI editor/palette) and depends on both package products. UI tasks are verified by `xcodebuild build` + manual UX checks.

**Tech Stack:** Swift 6, SwiftPM (library) + Xcode app target, SwiftUI `MenuBarExtra`, AppKit `NSPanel`/`NSPasteboard`/`NSHostingView`, Carbon `RegisterEventHotKey`, `PastefixCore`. Tests: Swift Testing.

## Global Constraints

- **Package additions stay dependency-free.** `PastefixAppCore` imports only Foundation + AppKit (system) and `PastefixCore`. No third-party SPM deps in Plan 2a. (KeyboardShortcuts, Sparkle → Plan 2b.)
- **Deployment target macOS 14** (matches the package `.macOS(.v14)`). App is `LSUIElement = YES` (menu-bar only, no Dock icon).
- **Engine API is consumed, not modified.** `TransformerRegistry(config: RegistryConfig(scriptsDirectory:wrapWidth:timeout:)).load() -> [any Transformer]`; `Transformer` has `id`, `name`, `requiresRichInput`, `source`, `func apply(_ input: TransformInput) async throws -> String`; `TransformInput(text:richRTFD:)`; `TransformError` cases `richInputUnavailable` / `timeout` / `nonZeroExit(code:stderr:)` / `scriptFailed(String)`.
- **Rich→plain reads the ORIGIN clipboard, not the working text.** `TransformInput.richRTFD` is always the origin snapshot's RTFD data; a transform with `requiresRichInput == true` is only enabled when the origin snapshot has rich content.
- **The editor is plain-text only; transforms operate on the whole buffer.** (Per spec.)
- **Default hotkey ⌘⇧C; default wrap width 400** (the `RegistryConfig` default). Both are fixed in 2a; making them configurable is 2b.
- **Save writes plain text to `NSPasteboard.general` and hides the panel; Cancel/Esc hides without changing the pasteboard.**

---

## File Structure

```
Package.swift                              # add PastefixAppCore library target + product
Sources/PastefixAppCore/
  ClipboardSnapshot.swift                  # value type: plainText + richRTFD (from NSAttributedString)
  PasteDocument.swift                      # origin + history/cursor, undo/redo, refresh
  TransformCoordinator.swift               # apply(transformer, to: document) + isEnabled(_:for:)
Tests/PastefixAppCoreTests/
  ClipboardSnapshotTests.swift
  PasteDocumentTests.swift
  TransformCoordinatorTests.swift

Pastefix.xcodeproj/                        # USER-scaffolded (Task 2)
Pastefix/                                  # Xcode app target sources (agents fill in)
  PastefixApp.swift                        # @main, MenuBarExtra, wires hotkey -> AppModel
  AppModel.swift                           # ObservableObject: registry, document, actions
  GlobalHotkey.swift                       # Carbon RegisterEventHotKey wrapper (fixed ⌘⇧C)
  ClipboardBridge.swift                    # NSPasteboard <-> ClipboardSnapshot
  PanelController.swift                    # NSPanel (nonactivating, floating) hosting SwiftUI
  PanelView.swift                          # editor + palette + toolbar + error banner
Info.plist / target settings               # LSUIElement = YES (set during scaffold)
```

---

## Task 1: Add the `PastefixAppCore` library target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PastefixAppCore/Placeholder.swift` (temporary, removed in Task 3)
- Create: `Tests/PastefixAppCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: the existing `PastefixCore` target.
- Produces: a library product `PastefixAppCore` (depends on `PastefixCore`) and a test target `PastefixAppCoreTests`, both building green. This product is what the Xcode app links in Task 2.

- [ ] **Step 1: Edit `Package.swift`**

Add the product, target, and test target (keep the existing `PastefixCore` entries):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PastefixCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PastefixCore", targets: ["PastefixCore"]),
        .library(name: "PastefixAppCore", targets: ["PastefixAppCore"]),
    ],
    targets: [
        .target(name: "PastefixCore"),
        .testTarget(
            name: "PastefixCoreTests",
            dependencies: ["PastefixCore"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "PastefixAppCore", dependencies: ["PastefixCore"]),
        .testTarget(name: "PastefixAppCoreTests", dependencies: ["PastefixAppCore"]),
    ]
)
```

- [ ] **Step 2: Add a temporary placeholder so the target compiles**

Create `Sources/PastefixAppCore/Placeholder.swift`:

```swift
// Removed in Task 3 once ClipboardSnapshot lands.
enum PastefixAppCorePlaceholder {}
```

- [ ] **Step 3: Write a smoke test**

Create `Tests/PastefixAppCoreTests/SmokeTests.swift`:

```swift
import Testing
@testable import PastefixAppCore

@Test func targetBuilds() {
    #expect(Bool(true))
}
```

- [ ] **Step 4: Build and test**

Run: `swift test`
Expected: PASS — the existing engine suite plus the new smoke test; no regressions.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/PastefixAppCore/Placeholder.swift Tests/PastefixAppCoreTests/SmokeTests.swift
git commit -m "feat(appcore): add PastefixAppCore library target"
```

---

## Task 2: USER scaffolds the Xcode app target (manual prerequisite)

**This task is performed by the human, not a subagent.** The controller must not dispatch an implementer for it — instead, present these steps to the user, wait, then verify.

**Files (created by Xcode):** `Pastefix.xcodeproj/`, `Pastefix/` sources, app `Info.plist`.

**Steps for the user:**

1. In Xcode: **File → New → Project → macOS → App**. Product Name `Pastefix`, Interface **SwiftUI**, Language **Swift**. Save it at the repo root (`/Users/bnaylor/src/pastefix`) so `Pastefix.xcodeproj` and `Pastefix/` sit beside `Package.swift`.
2. Select the `Pastefix` target → **General** → set **Minimum Deployments = macOS 14.0**.
3. **Info tab** (or target Info.plist): add key **Application is agent (UIElement)** = **YES** (`LSUIElement`).
4. **File → Add Package Dependencies… → Add Local…** → choose the repo root package. Add **both** library products to the `Pastefix` target: **PastefixCore** and **PastefixAppCore**.
5. Delete the template `ContentView.swift` (its contents will be replaced; leaving an empty struct is fine, or remove it — later tasks create the real views).
6. Build once in Xcode (⌘B) to confirm it compiles, then commit:
   ```bash
   git add Pastefix.xcodeproj Pastefix
   git commit -m "chore(app): scaffold Pastefix Xcode app target (LSUIElement, links PastefixCore + PastefixAppCore)"
   ```

- [ ] **Controller verification (before dispatching Task 3):**

Run:
```bash
xcodebuild -list -project Pastefix.xcodeproj
xcodebuild build -project Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' -quiet
```
Expected: the `Pastefix` scheme is listed and the build succeeds. If the scheme is missing or the package products aren't linked, return to the user with the specific gap before proceeding.

---

## Task 3: `ClipboardSnapshot` (PastefixAppCore, TDD)

**Files:**
- Create: `Sources/PastefixAppCore/ClipboardSnapshot.swift`
- Delete: `Sources/PastefixAppCore/Placeholder.swift`
- Test: `Tests/PastefixAppCoreTests/ClipboardSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct ClipboardSnapshot: Sendable` with `let plainText: String?`, `let richRTFD: Data?`, `init(plainText:richRTFD:)`, a convenience `init(plainText:rich: NSAttributedString?)` that serializes `rich` to RTFD `Data`, and `var hasRichContent: Bool` (`richRTFD != nil`).

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixAppCoreTests/ClipboardSnapshotTests.swift`:

```swift
import Testing
import AppKit
@testable import PastefixAppCore

@Suite struct ClipboardSnapshotTests {
    @Test func plainOnlyHasNoRichContent() {
        let snap = ClipboardSnapshot(plainText: "hello", rich: nil)
        #expect(snap.plainText == "hello")
        #expect(snap.richRTFD == nil)
        #expect(snap.hasRichContent == false)
    }

    @Test func richProducesRTFDAndReconstructsPlain() throws {
        let styled = NSAttributedString(
            string: "Bold",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]
        )
        let snap = ClipboardSnapshot(plainText: "Bold", rich: styled)
        #expect(snap.hasRichContent == true)
        let data = try #require(snap.richRTFD)
        let round = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        #expect(round.string == "Bold")
    }

    @Test func memberwiseInitStoresDataDirectly() {
        let snap = ClipboardSnapshot(plainText: nil, richRTFD: Data([1, 2, 3]))
        #expect(snap.plainText == nil)
        #expect(snap.hasRichContent == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ClipboardSnapshotTests`
Expected: FAIL — `ClipboardSnapshot` undefined.

- [ ] **Step 3: Implement, and remove the placeholder**

Delete `Sources/PastefixAppCore/Placeholder.swift`. Create `Sources/PastefixAppCore/ClipboardSnapshot.swift`:

```swift
import Foundation
import AppKit

/// An immutable capture of the clipboard at summon time. `plainText` seeds the
/// editor; `richRTFD` is the original rich content (as RTFD data) that the
/// rich->plain transform reads.
public struct ClipboardSnapshot: Sendable {
    public let plainText: String?
    public let richRTFD: Data?

    public init(plainText: String?, richRTFD: Data?) {
        self.plainText = plainText
        self.richRTFD = richRTFD
    }

    public init(plainText: String?, rich: NSAttributedString?) {
        self.plainText = plainText
        self.richRTFD = rich.flatMap { attributed in
            try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )
        }
    }

    public var hasRichContent: Bool { richRTFD != nil }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ClipboardSnapshotTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/ClipboardSnapshot.swift Tests/PastefixAppCoreTests/ClipboardSnapshotTests.swift
git rm Sources/PastefixAppCore/Placeholder.swift
git commit -m "feat(appcore): add ClipboardSnapshot"
```

---

## Task 4: `PasteDocument` (PastefixAppCore, TDD)

**Files:**
- Create: `Sources/PastefixAppCore/PasteDocument.swift`
- Test: `Tests/PastefixAppCoreTests/PasteDocumentTests.swift`

**Interfaces:**
- Consumes: `ClipboardSnapshot` (Task 3).
- Produces: `struct PasteDocument: Sendable` with `let origin: ClipboardSnapshot`, `private(set) var history: [String]`, `private(set) var cursor: Int`, `init(origin:)` (history = `[origin.plainText ?? ""]`, cursor 0), computed `var working: String`, `var canUndo/canRedo: Bool`, `mutating func pushState(_:)` (skips when equal to `working`, truncates redo tail), `mutating func setWorking(_:)` (in-place edit of the current state), `mutating func undo()`, `mutating func redo()`, `mutating func refresh(origin:)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixAppCoreTests/PasteDocumentTests.swift`:

```swift
import Testing
@testable import PastefixAppCore

@Suite struct PasteDocumentTests {
    private func doc(_ text: String) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: nil))
    }

    @Test func startsWithOriginText() {
        let d = doc("hi")
        #expect(d.working == "hi")
        #expect(d.canUndo == false)
        #expect(d.canRedo == false)
    }

    @Test func nilOriginTextStartsEmpty() {
        let d = PasteDocument(origin: ClipboardSnapshot(plainText: nil, richRTFD: nil))
        #expect(d.working == "")
    }

    @Test func pushEnablesUndo() {
        var d = doc("a")
        d.pushState("b")
        #expect(d.working == "b")
        #expect(d.canUndo == true)
        d.undo()
        #expect(d.working == "a")
        #expect(d.canRedo == true)
        d.redo()
        #expect(d.working == "b")
    }

    @Test func pushTruncatesRedoTail() {
        var d = doc("a")
        d.pushState("b")
        d.pushState("c")
        d.undo()               // back to "b"
        d.pushState("d")       // truncates "c"
        #expect(d.working == "d")
        #expect(d.canRedo == false)
    }

    @Test func pushIsNoOpWhenUnchanged() {
        var d = doc("a")
        d.pushState("a")
        #expect(d.canUndo == false)
    }

    @Test func setWorkingEditsInPlace() {
        var d = doc("a")
        d.pushState("b")
        d.setWorking("b-edited")
        #expect(d.working == "b-edited")
        d.undo()
        #expect(d.working == "a")   // the edit stayed on the "b" state, not a new one
    }

    @Test func refreshResets() {
        var d = doc("a")
        d.pushState("b")
        d.refresh(origin: ClipboardSnapshot(plainText: "fresh", richRTFD: nil))
        #expect(d.working == "fresh")
        #expect(d.canUndo == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PasteDocumentTests`
Expected: FAIL — `PasteDocument` undefined.

- [ ] **Step 3: Implement**

Create `Sources/PastefixAppCore/PasteDocument.swift`:

```swift
import Foundation

/// The editing session for one summon: the origin clipboard snapshot plus a
/// linear history of working-text states with an undo/redo cursor.
public struct PasteDocument: Sendable {
    public let origin: ClipboardSnapshot
    public private(set) var history: [String]
    public private(set) var cursor: Int

    public init(origin: ClipboardSnapshot) {
        self.origin = origin
        self.history = [origin.plainText ?? ""]
        self.cursor = 0
    }

    public var working: String { history[cursor] }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count - 1 }

    /// Append a new state (e.g. a transform result). No-op if unchanged.
    public mutating func pushState(_ text: String) {
        guard text != working else { return }
        history = Array(history.prefix(cursor + 1))
        history.append(text)
        cursor = history.count - 1
    }

    /// Coalesce a manual edit into the current state (no new history entry).
    public mutating func setWorking(_ text: String) {
        history[cursor] = text
    }

    public mutating func undo() { if canUndo { cursor -= 1 } }
    public mutating func redo() { if canRedo { cursor += 1 } }

    public mutating func refresh(origin: ClipboardSnapshot) {
        self = PasteDocument(origin: origin)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PasteDocumentTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/PasteDocument.swift Tests/PastefixAppCoreTests/PasteDocumentTests.swift
git commit -m "feat(appcore): add PasteDocument with undo/redo history"
```

---

## Task 5: `TransformCoordinator` (PastefixAppCore, TDD)

**Files:**
- Create: `Sources/PastefixAppCore/TransformCoordinator.swift`
- Test: `Tests/PastefixAppCoreTests/TransformCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PasteDocument` (Task 4), `ClipboardSnapshot` (Task 3), and `PastefixCore`'s `Transformer` / `TransformInput` / `TransformError`.
- Produces:
  - `enum TransformOutcome: Sendable, Equatable { case applied; case unchanged; case failed(String) }`
  - `enum TransformCoordinator` with:
    - `static func isEnabled(_ transformer: any Transformer, for document: PasteDocument) -> Bool` — `requiresRichInput` transforms enabled only when `document.origin.hasRichContent`.
    - `static func apply(_ transformer: any Transformer, to document: PasteDocument) async -> (PasteDocument, TransformOutcome)` — builds `TransformInput(text: document.working, richRTFD: document.origin.richRTFD)`, awaits `apply`, pushes the result (or returns `.unchanged`), maps `TransformError` to a human message on failure. Returns an updated copy; never mutates via `inout`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixAppCoreTests/TransformCoordinatorTests.swift`:

```swift
import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

private struct FakeTransformer: Transformer {
    let id: String
    let name: String
    let requiresRichInput: Bool
    let source: TransformerSource = .builtin
    let behavior: @Sendable (TransformInput) async throws -> String
    func apply(_ input: TransformInput) async throws -> String { try await behavior(input) }
}

@Suite struct TransformCoordinatorTests {
    private func doc(_ text: String, rich: Bool = false) -> PasteDocument {
        PasteDocument(origin: ClipboardSnapshot(plainText: text, richRTFD: rich ? Data([1]) : nil))
    }

    @Test func applySuccessPushesResult() async {
        let t = FakeTransformer(id: "x", name: "X", requiresRichInput: false) { input in
            input.text.uppercased()
        }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .applied)
        #expect(updated.working == "HI")
        #expect(updated.canUndo == true)
    }

    @Test func applyUnchangedReportsUnchanged() async {
        let t = FakeTransformer(id: "id", name: "Id", requiresRichInput: false) { $0.text }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .unchanged)
        #expect(updated.canUndo == false)
    }

    @Test func applyFailureReturnsMessageAndLeavesDocument() async {
        let t = FakeTransformer(id: "f", name: "F", requiresRichInput: false) { _ in
            throw TransformError.timeout
        }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("The transform timed out."))
        #expect(updated.working == "hi")
        #expect(updated.canUndo == false)
    }

    @Test func richTransformPassesOriginRTFD() async {
        let t = FakeTransformer(id: "r", name: "R", requiresRichInput: true) { input in
            input.richRTFD == nil ? "NO-RICH" : "HAS-RICH"
        }
        let (updated, _) = await TransformCoordinator.apply(t, to: doc("hi", rich: true))
        #expect(updated.working == "HAS-RICH")
    }

    @Test func isEnabledGatesRichOnOriginContent() {
        let rich = FakeTransformer(id: "r", name: "R", requiresRichInput: true) { $0.text }
        let plain = FakeTransformer(id: "p", name: "P", requiresRichInput: false) { $0.text }
        #expect(TransformCoordinator.isEnabled(rich, for: doc("x", rich: false)) == false)
        #expect(TransformCoordinator.isEnabled(rich, for: doc("x", rich: true)) == true)
        #expect(TransformCoordinator.isEnabled(plain, for: doc("x", rich: false)) == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TransformCoordinatorTests`
Expected: FAIL — `TransformCoordinator` undefined.

- [ ] **Step 3: Implement**

Create `Sources/PastefixAppCore/TransformCoordinator.swift`:

```swift
import Foundation
import PastefixCore

public enum TransformOutcome: Sendable, Equatable {
    case applied
    case unchanged
    case failed(String)
}

public enum TransformCoordinator {
    public static func isEnabled(_ transformer: any Transformer, for document: PasteDocument) -> Bool {
        if transformer.requiresRichInput { return document.origin.hasRichContent }
        return true
    }

    public static func apply(
        _ transformer: any Transformer,
        to document: PasteDocument
    ) async -> (PasteDocument, TransformOutcome) {
        var doc = document
        let input = TransformInput(text: doc.working, richRTFD: doc.origin.richRTFD)
        do {
            let result = try await transformer.apply(input)
            if result == doc.working { return (doc, .unchanged) }
            doc.pushState(result)
            return (doc, .applied)
        } catch let error as TransformError {
            return (doc, .failed(message(for: error)))
        } catch {
            return (doc, .failed(error.localizedDescription))
        }
    }

    static func message(for error: TransformError) -> String {
        switch error {
        case .richInputUnavailable: return "No rich text available to convert."
        case .timeout: return "The transform timed out."
        case .nonZeroExit(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Script failed (exit \(code))." : "Script failed (exit \(code)): \(detail)"
        case .scriptFailed(let msg): return "Script error: \(msg)"
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TransformCoordinatorTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/TransformCoordinator.swift Tests/PastefixAppCoreTests/TransformCoordinatorTests.swift
git commit -m "feat(appcore): add TransformCoordinator bridging engine and document"
```

---

## Task 6: `GlobalHotkey` (Carbon, app target, build-verify)

**Files:**
- Create: `Pastefix/GlobalHotkey.swift`

**Interfaces:**
- Consumes: nothing from the package.
- Produces: `final class GlobalHotkey` with `init(onFire: @escaping () -> Void)`, `func register()`, `func unregister()`. Registers ⌘⇧C globally via `RegisterEventHotKey`; the installed Carbon event handler calls `onFire` on the main thread. `deinit` calls `unregister()`.

- [ ] **Step 1: Implement**

Create `Pastefix/GlobalHotkey.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// A fixed global hotkey (Cmd-Shift-C) via Carbon RegisterEventHotKey.
/// No Accessibility permission required. Rebindable hotkeys are a Plan 2b concern.
final class GlobalHotkey {
    private let onFire: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x50465831 // 'PFX1'

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    deinit { unregister() }

    func register() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotkey.onFire() }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' -quiet`
Expected: build succeeds (no reference to `GlobalHotkey` yet — this only proves it compiles).

- [ ] **Step 3: Commit**

```bash
git add Pastefix/GlobalHotkey.swift
git commit -m "feat(app): add Carbon global hotkey (Cmd-Shift-C)"
```

---

## Task 7: `ClipboardBridge` + `PanelController` (app target, build-verify)

**Files:**
- Create: `Pastefix/ClipboardBridge.swift`
- Create: `Pastefix/PanelController.swift`

**Interfaces:**
- Consumes: `ClipboardSnapshot` (`PastefixAppCore`).
- Produces:
  - `enum ClipboardBridge` with `static func snapshot(from: NSPasteboard = .general) -> ClipboardSnapshot` and `static func writePlain(_ text: String, to: NSPasteboard = .general)`.
  - `final class PanelController` with `init(rootView:)` (takes an `NSView` — the hosted SwiftUI content), `func show()`, `func hide()`, and a settable `onResignKey: (() -> Void)?` (unused in 2a; wired for 2b auto-hide). Uses a `.nonactivatingPanel`, `.floating` level `NSPanel`.

- [ ] **Step 1: Implement `ClipboardBridge`**

Create `Pastefix/ClipboardBridge.swift`:

```swift
import AppKit
import PastefixAppCore

enum ClipboardBridge {
    static func snapshot(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let plain = pasteboard.string(forType: .string)
        let rich = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?
            .first as? NSAttributedString
        return ClipboardSnapshot(plainText: plain, rich: rich)
    }

    static func writePlain(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Implement `PanelController`**

Create `Pastefix/PanelController.swift`:

```swift
import AppKit

/// Owns the floating panel that hosts the SwiftUI editor. A panel (not a window)
/// so it can appear over full-screen apps without switching Spaces.
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    var onResignKey: (() -> Void)?   // wired for Plan 2b auto-hide-on-blur

    init(rootView: NSView) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.contentView = rootView
        super.init()
        panel.delegate = self
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' -quiet`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Pastefix/ClipboardBridge.swift Pastefix/PanelController.swift
git commit -m "feat(app): add clipboard bridge and floating panel controller"
```

---

## Task 8: `AppModel` (app target, build-verify)

**Files:**
- Create: `Pastefix/AppModel.swift`

**Interfaces:**
- Consumes: `PastefixCore` (`TransformerRegistry`, `RegistryConfig`, `Transformer`), `PastefixAppCore` (`PasteDocument`, `TransformCoordinator`, `TransformOutcome`, `ClipboardSnapshot`), `ClipboardBridge` (Task 7).
- Produces: `@MainActor final class AppModel: ObservableObject` with:
  - `@Published private(set) var document: PasteDocument?` (nil when no active session)
  - `@Published var errorMessage: String?`
  - `let transformers: [any Transformer]` (loaded once via the registry)
  - `func summon()` — snapshot pasteboard, set `document`, clear error
  - `func enabledTransformers() -> [any Transformer]`
  - `func apply(_ transformer: any Transformer)` — async apply via coordinator, update `document`/`errorMessage`
  - `func undo()`, `func redo()`, `func setWorking(_:)`, `func refresh()`
  - `func save()` — write `document.working` to the pasteboard, then `endSession()`
  - `func cancel()` — `endSession()` without touching the pasteboard
  - `var onEndSession: (() -> Void)?` — hook the app uses to hide the panel

- [ ] **Step 1: Implement**

Create `Pastefix/AppModel.swift`:

```swift
import Foundation
import AppKit
import PastefixCore
import PastefixAppCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var document: PasteDocument?
    @Published var errorMessage: String?

    let transformers: [any Transformer]
    var onEndSession: (() -> Void)?

    init() {
        let scriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pastefix/scripts", isDirectory: true)
        let registry = TransformerRegistry(config: RegistryConfig(scriptsDirectory: scriptsDir))
        transformers = registry.load()
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
        guard let current = document else { return }
        Task {
            let (updated, outcome) = await TransformCoordinator.apply(transformer, to: current)
            self.document = updated
            switch outcome {
            case .applied, .unchanged: self.errorMessage = nil
            case .failed(let message): self.errorMessage = message
            }
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

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' -quiet`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Pastefix/AppModel.swift
git commit -m "feat(app): add AppModel wiring engine, document, and clipboard"
```

---

## Task 9: `PanelView` + `PastefixApp` (app target, build-verify)

**Files:**
- Create: `Pastefix/PanelView.swift`
- Create: `Pastefix/PastefixApp.swift` (replaces the template `@main` app file — remove the scaffold's default app struct and `ContentView` if still present)
- Modify: `README.md`

**Interfaces:**
- Consumes: `AppModel` (Task 8), `GlobalHotkey` (Task 6), `PanelController` (Task 7), `PastefixCore.Transformer`.
- Produces: the SwiftUI `PanelView` (editor + palette + toolbar + error banner) and the `@main` `PastefixApp` with a `MenuBarExtra`, wiring the hotkey to `AppModel.summon()` and hosting `PanelView` in the panel.

- [ ] **Step 1: Implement `PanelView`**

Create `Pastefix/PanelView.swift`:

```swift
import SwiftUI
import PastefixCore

struct PanelView: View {
    @ObservedObject var model: AppModel

    private var workingBinding: Binding<String> {
        Binding(
            get: { model.document?.working ?? "" },
            set: { model.setWorking($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TextEditor(text: workingBinding)
                .font(.system(.body, design: .monospaced))
                .padding(8)
            if let error = model.errorMessage {
                errorBanner(error)
            }
            Divider()
            palette
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    private var toolbar: some View {
        HStack {
            Button("Undo") { model.undo() }
                .disabled(model.document?.canUndo != true)
            Button("Redo") { model.redo() }
                .disabled(model.document?.canRedo != true)
            Button("Refresh") { model.refresh() }
            Spacer()
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .keyboardShortcut(.defaultAction)
        }
        .padding(8)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.red.opacity(0.85))
    }

    private var palette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.enabledTransformers(), id: \.id) { transformer in
                    Button(transformer.name) { model.apply(transformer) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(8)
        }
    }
}
```

- [ ] **Step 2: Implement `PastefixApp`**

Remove the scaffold's default `@main` app struct and `ContentView` (if the user left them). Create `Pastefix/PastefixApp.swift`:

```swift
import SwiftUI
import AppKit

@main
struct PastefixApp: App {
    @StateObject private var model = AppModel()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra("Pastefix", systemImage: "doc.on.clipboard") {
            Button("Summon Pastefix") { coordinator.summon() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .onChange(of: model.document == nil) { _, _ in }  // keeps model alive with the scene
        .commands { }
        .also { coordinator.attach(model: model) }
    }
}

/// Bridges the SwiftUI scene to AppKit: owns the hotkey and the panel, both of
/// which are AppKit objects that must outlive individual view updates.
@MainActor
final class AppCoordinator {
    private var model: AppModel?
    private var hotkey: GlobalHotkey?
    private var panel: PanelController?

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.onEndSession = { [weak self] in self?.panel?.hide() }

        let hosting = NSHostingView(rootView: PanelView(model: model))
        let panel = PanelController(rootView: hosting)
        self.panel = panel

        let hotkey = GlobalHotkey(onFire: { [weak self] in self?.summon() })
        hotkey.register()
        self.hotkey = hotkey
    }

    func summon() {
        model?.summon()
        panel?.show()
    }
}

private extension Scene {
    /// Runs a side effect once while building the scene (used to attach AppKit glue).
    func also(_ body: () -> Void) -> some Scene {
        body()
        return self
    }
}
```

> Implementer note: SwiftUI `App` + AppKit glue has a few valid shapes. If `.also`/`attach` timing proves flaky (e.g. `model` not ready), fall back to an `NSApplicationDelegateAdaptor` that owns `AppCoordinator` and receives the `AppModel` — but keep `AppModel` the single source of truth and do NOT change its interface. Report which shape you used.

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' -quiet`
Expected: build succeeds.

- [ ] **Step 4: Update the README**

Add a "The app (Plan 2a)" section to `README.md`: what the menu-bar app does, the ⌘⇧C summon → transform → Save flow, and that it's the core (Settings, live script reload, auto-updates are forthcoming in 2b).

- [ ] **Step 5: Commit**

```bash
git add Pastefix/PanelView.swift Pastefix/PastefixApp.swift README.md
git commit -m "feat(app): menu-bar app with summon panel, palette, and save"
```

---

## Task 10: USER manual UX verification (manual)

**This task is performed by the human.** The controller presents the checklist and records the result; it does not dispatch a subagent.

- [ ] **Step 1: Launch**

Run: `xcodebuild build -project Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' -configuration Debug -quiet` then open the built `.app` (path from `xcodebuild -showBuildSettings … | grep TARGET_BUILD_DIR`), or launch from Xcode (⌘R). Confirm a menu-bar icon appears and there is no Dock icon.

- [ ] **Step 2: Summon**

Copy some rich text (e.g. from a browser), press **⌘⇧C**. Confirm the floating panel appears with the plain text loaded, over whatever app was focused.

- [ ] **Step 3: Transform**

Confirm the palette shows the built-ins; "Rich → Plain Text" is present (rich clipboard). Click **Transliterate to ASCII** and **Whitespace Cleanup**; confirm the text changes and **Undo**/**Redo** work. Copy plain-only text, Refresh, and confirm "Rich → Plain Text" is now absent/disabled.

- [ ] **Step 4: Save & paste**

Click **Save** (or ⌘S); confirm the panel hides. Paste into a plain-text field and confirm the transformed text is what lands. Summon again, click **Cancel** (Esc); confirm the clipboard is unchanged.

- [ ] **Step 5: Script (optional)**

Drop an executable `~/.config/pastefix/scripts/shout.sh` (`#!/bin/sh` / `# pastefix: name = Shout` / `tr '[:lower:]' '[:upper:]'`), relaunch, summon, and confirm "Shout" appears in the palette and works. (Live reload without relaunch is Plan 2b.)

Report any step that fails; those become fix-loop findings for the relevant task.

---

## Self-Review

**Spec coverage** (against `docs/specs/2026-08-11-pastefix-v2-foundation-pipeline.md`, app sections):

- Non-sandboxed `LSUIElement` menu-bar app → Task 2 scaffold. ✓
- `MenuBarExtra` (summon, quit) → Task 9. ✓ (Settings/Check-for-Updates entries are Plan 2b.)
- Floating `NSPanel` (nonactivating, floating) summoned by global hotkey (⌘⇧C) → Tasks 6, 7, 9. ✓
- Summon sequence: snapshot pasteboard (plain + rich), load plain into editor → Tasks 3, 7, 8. ✓ (Frontmost-app capture for future auto-paste is deferred with auto-paste — noted, not in 2a.)
- Save (⌘S) writes plain text + hides; Cancel (Esc) hides unchanged → Tasks 8, 9. ✓
- `PasteDocument` (origin + history/cursor, undo/redo, refresh); rich→plain reads origin; plain-text editor; whole-buffer transforms → Tasks 3–5, 9. ✓
- Palette of actions: click to apply, stack with undo, inline error → Tasks 5, 8, 9. ✓
- **Deferred to Plan 2b (correctly out of scope):** Settings + `UserDefaults` persistence, KeyboardShortcuts rebinding/recorder, Sparkle updates, auto-hide-on-blur (the hook exists on `PanelController` but is unwired), live script reload via `ScriptWatcher`, configurable wrap width. Auto-paste into the previous app is deferred with its dependency.

**Placeholder scan:** no TBD/TODO. The `Placeholder.swift` in Task 1 is a named temporary explicitly deleted in Task 3. Task 9's implementer note offers a concrete fallback (NSApplicationDelegateAdaptor), not a vague one.

**Type consistency:** `ClipboardSnapshot(plainText:richRTFD:)` / `(plainText:rich:)`, `hasRichContent`; `PasteDocument(origin:)`, `working`, `pushState`, `setWorking`, `undo`, `redo`, `refresh(origin:)`, `canUndo`, `canRedo`; `TransformOutcome` (`applied`/`unchanged`/`failed(String)`); `TransformCoordinator.isEnabled(_:for:)` / `apply(_:to:)`; `ClipboardBridge.snapshot(from:)` / `writePlain(_:to:)`; `PanelController(rootView:)` / `show()` / `hide()` / `onResignKey`; `AppModel` published `document`/`errorMessage`, `transformers`, `summon`/`enabledTransformers`/`apply`/`undo`/`redo`/`setWorking`/`refresh`/`save`/`cancel`/`onEndSession` — used consistently across Tasks 3–9. Engine API (`TransformerRegistry`, `RegistryConfig`, `Transformer`, `TransformInput`, `TransformError`) matches the shipped `PastefixCore`.

**Verification honesty:** Tasks 3–5 are `swift test` TDD. Tasks 6–9 gate on `xcodebuild build` success (subagents cannot exercise a menu-bar hotkey or paste). Tasks 2 and 10 are explicitly human-performed; the controller must not dispatch subagents for them and must verify their outputs (build/scheme for Task 2; the UX checklist for Task 10) before proceeding/closing.
