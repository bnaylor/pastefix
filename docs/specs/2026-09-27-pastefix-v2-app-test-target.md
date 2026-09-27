---
type: spec
status: implemented
id: 2026-09-27-pastefix-v2-app-test-target
title: Pastefix v2 — A test target for the app (Plan 18, #68)
description: A hosted unit-test target for Pastefix.app, so AppModel and ClipboardBridge can be tested, with a test-mode guard that stops a test run from touching the user's hotkeys, clipboard, history or settings. Backfills only tests that map to defects that actually shipped, each mutation-checked against the historical fix it pins.
tags: [pastefix, macos, swift, testing, infrastructure]
timestamp: 2026-09-27T00:00:00Z
---

# Pastefix v2 — A test target for the app (Plan 18)

Source: [#68](https://github.com/bnaylor/pastefix/issues/68). The Xcode project has exactly one
target, the application. `PastefixCore` and `PastefixAppCore` have ~700 tests between them. The
app has none, and it's where the defects that cost real time lived. Plans 13 and 15 (listed on the
issue), plus these from 2026-09-26/27:

| Defect | Where | Caught by |
|---|---|---|
| `AppModel.load` put an unvalidated history blob into a session; a zero-byte blob became `imagePNG == Data()` and ⌘S wrote a zero-byte PNG | `AppModel` | final review |
| The Save guard, wrong in the permissive direction, destroyed an over-ceiling image in a mixed unedited session | `AppModel.save` | the implementer |
| The armed-Markdown Save branch passed `doc.imagePNG`, bypassing `SavePayload` | `AppModel.save` | peer review |
| The focus guard suppressed editor focus in ordinary mixed text sessions | `PanelView` | final review |

## The one decision that matters: host, and what hosting costs

**Chosen: a unit-test target hosted by the app** (`TEST_HOST` = Pastefix.app), because the logic
under test (`AppModel`, `ClipboardBridge`) lives in the app module, and hosting is how an Xcode
test target reaches an app module's internals.

**Rejected: an unhosted logic target that compiles the app's sources a second time.** The project
uses a synchronized root folder (objectVersion 77), so every app file would need a membership
exception pair. `PastefixApp.swift` (`@main`) would have to be excluded, and KeyboardShortcuts and
Sparkle linked into the test bundle. It avoids launching the app, but it creates a second
compilation of the app whose membership can drift from the first. That kind of silent divergence
is what this codebase keeps learning not to build.

**The cost of hosting**, which is the real work of this plan: a test run **launches the app**, and
unguarded, the app would, on the user's own machine:

1. register **global hotkeys**, colliding with an installed Pastefix that is running;
2. start `PasteboardMonitor`, reading the **real clipboard** and writing the **real history**
   (`~/Library/Application Support/Pastefix/history`);
3. start **Sparkle**'s scheduled update checks;
4. read and write the **real settings domain**, since the Debug build shares the bundle ID;
5. and through `ClipboardBridge`'s `.general` defaults, **write the user's clipboard** from any
   test of Save or copy-back.

## Amended during implementation (all verified)

- **The guard decides at `main`, not in the delegate.** The first version put it in `applicationDidFinishLaunching`, and the `work` session's review showed that was too late. Before it runs, the delegate's property initialisers have read the real settings and built Sparkle, the MenuBarExtra is installed, and the Settings scene has touched the lazy `HistoryStore`. On top of that, `applicationWillTerminate`'s flush would construct `HistoryStore` on the real directory and run its orphan-blob sweep. Now `PastefixEntry` picks `PastefixApp` or an inert `TestHostApp`, and `AppDelegate` is never created in a test host. A hosted test asserts that.
- **Detection accepts any of the four XCTest variables.** Measured on Xcode 26, in hosted runs on two machines: `XCTestSessionIdentifier`, `XCTestBundlePath` and `XCTestBundleInjectPath` are set. `XCTestConfigurationFilePath` is **not**, and the first version keyed on it alone, so it failed open. The decision is logged at `.notice` on every launch.
- **Verified on a second machine with the installed release running:** the general `changeCount`, the history directory and its index hash, the prefs plist mtime, and `~/.config/pastefix/scripts` were all identical before and after.
- The app target's `-showBuildSettings` is byte-identical before and after (Debug 588, Release 585), and the entitlements are untouched.
- `release.sh` refuses an app containing XCTest artefacts, because the test action copies them into the host. It's checked against a real test-host app (refused) and a plain build (allowed).

## Backfill: what's pinned, and how

Each test is pinned by **temporarily reverting the historical fix it names**, and the test fails.

| Defect | Test | Reverted fix → result |
|---|---|---|
| ⌘⇧U scanned a stale buffer (Plan 13, reached the user) | `UploadSnapshotTests` | "an open session always stands" → fails |
| Pastefix's own URL write counted as a user copy | `UploadSnapshotTests` | "our write counts" → fails |
| Zero-byte history blob became `Data()` | `SaveDefectTests` | unvalidated blob → fails |
| Permissive Save guard destroyed a refused image | `SaveDefectTests` | "unedited && payload empty" → fails |
| Markdown Save bypassed `SavePayload` | `SaveDefectTests` | raw origin image written → fails |
| `ClipboardBridge` image rules rested on a one-off probe | `ClipboardBridgeImageTests` | PNG re-encoded / TIFF preferred / refusal size lost / file-copy rule off → each fails |
| A hotkey shipped with no recorder | *structural*: `GlobalHotkey` drives recorders, registration (exhaustive `switch`) and validation | a fourth case → build fails: "switch must be exhaustive" |

**Covered at package level already, so not duplicated:** the sticky display form (`PasteDocumentImageTests`) and the focus guard's predicate (`isEmptyRefusedImageSession`).

**Not covered, stated:** that `PanelView` *calls* that predicate, and the upload overlay's header byte count. Both are view code, which is out of scope. The hotkey recorder has no test because a test would touch the `KeyboardShortcuts.Name` statics, which write defaults into the real settings domain inside a test host.

## Requirements

1. **Test-mode guard.** At launch, the app detects that it is hosting tests (the XCTest
   configuration environment variable, which Xcode sets for any hosted test run, Swift Testing
   included) and **starts nothing**: no hotkeys, no monitor, no Sparkle, no panel, no snippet
   hotkeys, and no `HistoryStore` on the real directory. The decision is a pure function in
   `PastefixAppCore` (`TestHostDetection.isHostingTests(environment:)`), tested there, so the guard
   can't be one mistyped key from silently doing nothing.
2. **An injectable pasteboard.** `AppModel` takes `pasteboard: NSPasteboard = .general` and passes
   it to every `ClipboardBridge` call. Tests use a uniquely named pasteboard and
   `releaseGlobally()` it afterwards. A test **never** touches `.general`, and a guard test asserts
   that the general pasteboard's `changeCount` is unchanged by the whole suite.
3. **Injected settings and history, always.** Tests construct `SettingsStore` on a unique suite
   and remove its persistent domain afterwards (not repeating #85), and `HistoryStore` on a
   per-test temporary directory.
4. **Runnable in one command**: `scripts/test-app.sh`, which wraps `xcodebuild test` with a
   private derived-data path, documented in AGENTS.md's Build section beside `swift test`.
5. **Backfill only tests that map to shipped defects**, one per row above and per the five on
   the issue, where the logic is reachable. **Each is mutation-checked by temporarily reverting
   the historical fix it pins**, and the test must fail. The revert and the failure are recorded
   in the commit message. A test that passes against the bug it's named for doesn't ship.
6. **SwiftUI views are out of scope**, as the issue says. Where a defect lived in a view (the
   focus guard), the plan either extracts the decision into a testable function or records why
   it can't.

## Out of scope

- UI tests (XCUITest). They would drive the keyboard, which on the owner's machine can't be done
  under automation (#76's mechanism).
- CI. There is none yet. The script is written so CI can call it later.
- Coverage targets. Six-plus targeted, mutation-checked tests, not a coverage push.

## Risks, named

- **Editing `project.pbxproj` by hand.** Do it via small, reviewed diffs, build after each, and
  check that the app target's settings are byte-identical apart from the scheme's test action.
  Invariant 9 (non-sandboxed) and Invariant 11 (hardened runtime, entitlements) must survive, so
  verify with `codesign -d --entitlements -`.
- **The guard failing open.** If detection breaks, a test run grabs hotkeys and writes real
  history. Mitigations: the detection function is unit-tested, and one hosted test asserts that
  the app delegate reports "started nothing" in the live host.
