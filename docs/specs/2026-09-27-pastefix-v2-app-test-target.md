---
type: spec
status: draft
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
