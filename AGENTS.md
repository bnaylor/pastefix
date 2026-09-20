# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Gemini CLI, etc.) working in this repo. Humans should read [README.md](README.md) and the current design spec under [`docs/specs/`](docs/specs/) first.

## What this project is

Pastefix v2 is a macOS clipboard utility: a menu-bar app with a global hotkey that summons an editable panel, applies text transforms (clean up for IRC/chat, reflow, rich→plain, user scripts), and writes the result back to the clipboard. It is the modern Swift rewrite of a 2007 Objective-C app.

The repo has three components:

- **`PastefixCore`** — the transform *engine*, a standalone, dependency-free Swift 6 SwiftPM package (macOS 14+). No UI. It defines a unified `Transformer` protocol over three engines (native Swift, shell, JavaScript), a registry that discovers user scripts, and an FSEvents watcher.
- **`PastefixAppCore`** — the app's *pure model* layer, a second SwiftPM library target (depends on `PastefixCore`). Holds the testable logic that must NOT live in the Xcode target: `ClipboardSnapshot`, `PasteDocument` (undo/redo history), `TransformCoordinator` (bridges engine → document). Unit-tested via `swift test`.
- **`Pastefix`** — the macOS menu-bar app, an **Xcode** target (SwiftUI `MenuBarExtra` + AppKit glue) that links both packages. Global hotkey (rebindable via KeyboardShortcuts, default ⌘⇧C) → floating `NSPanel` editor + transform palette → Save writes back to the pasteboard. Includes a Settings window for configurable wrap width, auto-hide-on-blur, custom scripts folder, hotkey rebinding, and per-transform enable/disable + reordering. Sparkle 2 provides auto-update (daily check, Check for Updates… menu item, Settings toggle). Built via `xcodebuild`, verified manually. **Third-party dependencies:** KeyboardShortcuts (sindresorhus) and Sparkle, both app-target only; both packages remain dependency-free.

**Testability rule:** pure logic belongs in `PastefixAppCore` (fast, headless `swift test`), NOT the Xcode target. The Xcode target is system glue only (hotkey, pasteboard, panel, SwiftUI views) and is not unit-tested. If you find yourself wanting to unit-test something in `Pastefix/`, it belongs in `PastefixAppCore`.

The authoritative design lives in `docs/specs/2026-08-11-pastefix-v2-foundation-pipeline.md`; per-increment plans under `docs/plans/`. Read the relevant one before non-trivial changes.

## Build, test, run

**Packages (`PastefixCore` + `PastefixAppCore`) — the tested logic:**

```sh
swift build                          # build both library targets
swift test                           # run the whole suite (engine + app model)
swift test --filter <SuiteName>      # focused, e.g. --filter ShellRunnerTests
```

**App (`Pastefix` Xcode target) — build + run:**

```sh
Pastefix/launch.sh                   # build Debug + launch the menu-bar app
Pastefix/launch.sh --path            # just print the built .app path
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix \
  -destination 'platform=macOS,arch=arm64' -configuration Debug   # build only
```

**Release (maintainers):** `scripts/release.sh X.Y.Z [--dry-run]` — notarized DMG to GitHub Releases + Sparkle appcast on `gh-pages`. Setup and recovery: `docs/RELEASING.md`.

### Fresh clone on a new machine

Everything needed to build is committed — the shared `Pastefix.xcscheme`, the SPM
`Package.resolved`, and no `DEVELOPMENT_TEAM` baked into the pbxproj. `git clone`,
open or `xcodebuild`, and the KeyboardShortcuts dependency resolves on its own.
Two caveats:

- **Signing:** `CODE_SIGN_STYLE = Automatic` with no team set signs locally for
  development. Releases are signed with the Developer ID for team `RMKGLPG4K4`
  and notarized by `scripts/release.sh`; that needs the certificate, the
  `pastefix-notary` keychain profile, and the Sparkle EdDSA private key on the
  machine (see `docs/RELEASING.md`).
- **Agent tooling:** this file and the plans under `docs/plans/` reference skills
  (`superpowers:*`, `swift-testing-pro`, `swiftui-pro`, `swift-concurrency-pro`)
  that may not be installed in every environment. They are conveniences, not
  requirements — the workflow they encode (TDD, plan-then-execute, verify before
  claiming done) applies regardless of whether the skills are available.

- Toolchain: Swift 6 (developed on 6.3 / Xcode 26.4), strict concurrency.
- Tests use the built-in **Swift Testing** framework (`import Testing`, `@Test`, `#expect`) — not XCTest.
- Fixture scripts under `Tests/PastefixCoreTests/Fixtures/` are executed directly, so they **must be committed executable** (`git ls-files -s` shows mode `100755`).
- The Xcode project lives at `Pastefix/Pastefix.xcodeproj` and app sources at `Pastefix/Pastefix/` (note the double nesting). Xcode 16 **filesystem-synchronized groups** auto-add new `.swift` files to the target — do NOT hand-edit `project.pbxproj` to add sources. Linking a *package product* or changing a *build setting* is the exception (a human/controller does it in Xcode or a surgical value flip).
- `xcodebuild -showBuildSettings` reports the **Release** path unless you pass the matching `-configuration Debug`; the product lives in **DerivedData**, not a local `build/`. Use `launch.sh` and stop fighting it.

## Project layout

```
Package.swift                         # swift-tools 6.0, .macOS(.v14), product PastefixCore, NO deps
Sources/PastefixCore/
  Transformer.swift                   # protocol + TransformInput + TransformerSource + TransformError
  Native/                             # native Swift transforms (pure String -> String)
    RichToPlain.swift                 #   builtin.richtoplain  (order 10, requiresRichInput)
    Transliterate.swift               #   builtin.transliterate (order 20)
    WrapReflow.swift                  #   builtin.wrapreflow   (order 30, init(width:))
    WhitespaceCleanup.swift           #   builtin.whitespace   (order 40)
  Scripting/
    ScriptMetadata.swift              # magic-comment header parser
    ShellRunner.swift / ShellTransformer.swift   # stdin->stdout process engine
    JSRunner.swift   / JSTransformer.swift        # JavaScriptCore engine
  Discovery/
    TransformerRegistry.swift         # RegistryConfig + load(): merge & order built-ins + scripts
    ScriptWatcher.swift               # Debouncer + FSEvents ScriptWatcher (+ retained WatcherContext)
Tests/PastefixCoreTests/
  *Tests.swift                        # one suite per component
  Fixtures/                           # executable fixture scripts (100755)
Sources/PastefixAppCore/              # app pure model (depends on PastefixCore, NO third-party deps)
  ClipboardSnapshot.swift             # plainText + richRTFD (RTFD data, Sendable)
  PasteDocument.swift                 # origin + history/cursor undo/redo/refresh
  TransformCoordinator.swift          # apply(transformer, to: document) + isEnabled
  SettingsStore.swift                 # UserDefaults persistence (wrap width, auto-hide, scripts folder, per-transform enable/order)
  TransformOverrides.swift            # per-transform enable/disable + drag-reordering
Tests/PastefixAppCoreTests/           # swift-test suites for the model
Pastefix/                             # the Xcode app (KeyboardShortcuts + Sparkle dependencies only)
  Pastefix.xcodeproj                  # ENABLE_APP_SANDBOX = NO, ENABLE_HARDENED_RUNTIME = YES
  launch.sh                           # build Debug + open the .app
  Pastefix/                           # app sources (system glue only, no unit tests)
    PastefixApp.swift                 # @main MenuBarExtra + NSApplicationDelegateAdaptor
    AppModel.swift                    # @MainActor ObservableObject: registry+document+clipboard
    HotkeyName.swift                  # KeyboardShortcuts recorder + display helper
    SettingsView.swift                # SwiftUI Settings window (General/Shortcut/Transforms tabs)
    ClipboardBridge.swift             # NSPasteboard <-> ClipboardSnapshot
    PanelController.swift             # floating NSPanel host
    PanelView.swift                   # SwiftUI editor + palette + toolbar + error banner
    UpdaterController.swift           # Sparkle SPUStandardUpdaterController wrapper (+ Debug feed override)
    Info.plist                        # SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks, SUScheduledCheckInterval
    Pastefix.entitlements             # com.apple.security.cs.allow-jit only; NEVER app-sandbox
scripts/release.sh, scripts/ExportOptions.plist   # release pipeline (see docs/RELEASING.md)
docs/specs/  docs/plans/  docs/reviews/   # dated design docs (see below)
```

## Critical invariants — DO NOT BREAK

These are load-bearing; most were established the hard way (see "Things that have bitten us").

1. **Transforms are single-purpose and composable.** Each transform does exactly one job. `Transliterate` strips/normalizes non-ASCII and **never touches whitespace** — collapsing spaces is `WhitespaceCleanup`'s job. Do not merge responsibilities to make one transform "smarter."
2. **A transform never corrupts the working buffer.** Timeout, non-zero shell exit, or a JS exception surface a typed `TransformError`; the caller keeps the prior text. `TransformError` cases (`richInputUnavailable`, `timeout`, `nonZeroExit(code:stderr:)`, `scriptFailed(String)`) are `Equatable` and consumed by tests — don't rename or repurpose them.
3. **Rich content travels as RTFD `Data?`, not `NSAttributedString`.** `TransformInput` must stay `Sendable` under the `async` protocol; only `RichToPlain` reconstructs the attributed string from `richRTFD`.
4. **`PastefixCore` and `PastefixAppCore` have ZERO external dependencies.** KeyboardShortcuts and Sparkle live in the app target only — never the engine or model layer. Adding a package dependency to `PastefixCore` or `PastefixAppCore` is a design change, not a convenience.
5. **Shell contract:** working text on **stdin → stdout**; the script file is executed directly so its shebang is honored; minimal scrubbed env; cwd = the script's directory. Drain stdout **and** stderr **concurrently** (`async let`) before `waitUntilExit()` — sequential draining deadlocks on >64KB stderr. The timeout is a **hard bound**: the child runs in its own process group and gets SIGTERM then SIGKILL after a short grace. `kill(-pid)` always uses the child's own positive PID — it must never be able to become `kill(0)` (caller's group) or `kill(-1)` (broadcast). `.nonZeroExit` stderr is truncated to a bounded tail.
6. **JS contract:** the script defines `function transform(text)`, run in a **fresh `JSContext` per call**; exceptions (read via `context.exception`) or a non-string return are errors. The eval/timeout race is guarded so the continuation resumes **exactly once**. JavaScriptCore cannot be interrupted, so a runaway script is abandoned best-effort on timeout (its thread runs until process exit) — this is documented, not a bug to "fix" by weakening the timeout.
7. **FSEvents lifetime:** the stream owns a **retained `WatcherContext` box** (via `passRetained`, balanced by the context `release` callback) — never `passUnretained(self)`, which is a use-after-free. `ScriptWatcher.stream` access is `NSLock`-guarded; `deinit` calls `stop()`.
8. **Transformer identities are stable and typed:** `builtin.<name>`, `shell:<filename>`, `js:<filename>`. Built-ins occupy orders 10/20/30/40; discovered scripts default to 1000; the registry sorts by `(order, name)` and returns only enabled transforms. Missing/unreadable script dirs are tolerated (built-ins still load).
9. **The app is NON-SANDBOXED (`ENABLE_APP_SANDBOX = NO`).** By design (direct-download, notarized). The sandbox would block reading `~/.config/pastefix/scripts/` and executing shell/JS scripts — i.e. it kills the entire user-scripts pipeline, the heart of the product. Xcode's app template re-enables the sandbox on a whim; if you regenerate or reconfigure the target, re-verify it stays off (`codesign -d --entitlements - <app>` must not show `com.apple.security.app-sandbox`).
10. **A slow transform must not lose the user's edit.** `AppModel.apply` is gated by `isApplying`: while an async transform (shell/JS, up to 3s) runs, the editor + palette are disabled so nothing mutates the document underneath the in-flight apply, and the result can't overwrite a newer edit. Don't remove the gate without a replacement that closes the same race.
11. **Hardened runtime + notarization are release requirements, and the Sparkle key is the root of trust.** `ENABLE_HARDENED_RUNTIME = YES` with `Pastefix.entitlements` carrying `com.apple.security.cs.allow-jit` (JavaScriptCore) and never `app-sandbox`. Sparkle lives only in the app target. The EdDSA private key in the maintainer's login keychain signs every update; a release signed with a different key is rejected by every installed copy, so the key is backed up and never regenerated, and `scripts/release.sh` refuses to ship if the keychain key does not match `SUPublicEDKey`. The `CFBundleVersion` Sparkle compares is `git rev-list --count HEAD` at release time — never hand-edit it in the pbxproj.

## Patterns and conventions

- **Native transforms** are pure `String -> String` (or `NSAttributedString -> String` for rich→plain) behind the `async throws` protocol. Keep the pure logic in a `static` helper so it's testable without the async surface.
- **New built-in transform** → new file in `Native/`, conform to `Transformer` with a `builtin.<id>` id and `.builtin` source, register it in `TransformerRegistry.load()` with an explicit order, and add a fixture-driven test suite (cover the nasty inputs: smart quotes, dingbats, CJK, wrap boundaries).
- **New script engine or metadata key** → extend `ScriptMetadata` / the runner protocol symmetrically with shell and JS; keep the magic-comment format (`# pastefix: key = value`, keys scanned in the first 30 lines, comment lead-ins `#`/`//`/`*`/`/*` tolerated).
- **Tests** live under `Tests/PastefixCoreTests/`, one suite per component, no mocking framework — real fixture scripts and real `NSAttributedString`/`JSContext` where needed.
- **Concurrency:** favor `async`/`async let` and small `@unchecked Sendable` lock boxes (see `Debouncer`, `ResumeGuard`) over ad-hoc threads; if you write `@unchecked Sendable`, the synchronization must actually exist.

## Things that have bitten us

Preserve these — each was a real defect caught in review or manual testing:

*Engine (initial build):*
- **Single-purpose transforms** (`fb6da56`): `Transliterate` originally collapsed spaces to satisfy a bad test. It must not; whitespace is a separate transform.
- **Shell pipe deadlock** (`96232ff`): sequential stdout-then-stderr draining hangs on large stderr. Drain concurrently.
- **Timeout wasn't a hard bound** (`5f4118e`): SIGTERM alone lets a trapping script hang the call; escalate to SIGKILL over the process group.
- **FSEvents use-after-free** (`d8ad95b`): `passUnretained(self)` in the stream context dangles; use a stream-owned retained box.
- **JS captured-var exception handler** (`8d65bc8`): reading `context.exception` directly beats a mutable `var` captured into a stored closure.

*App (Plan 2a) — both slipped past a green build and were caught only by manual UX testing, because they fail at runtime, not compile time:*
- **App Sandbox silently on** (`ed38589`): the Xcode template shipped `ENABLE_APP_SANDBOX = YES`, which built fine but made every user script invisible (can't read `~/.config`) — see invariant 9. Runtime-only failures need a human running the app, not just `xcodebuild`.
- **Fake rich detection** (`9cb3a60`): `NSPasteboard.readObjects([NSAttributedString])` *synthesizes* an attributed string even from plain text, so "Rich → Plain Text" was always enabled. Gate on `pasteboard.availableType(from: [.rtf, .rtfd, .html]) != nil` before treating the clipboard as rich.
- **Carbon callback UAF across the async hop** (`0aa45b5`) [HISTORICAL]: the `⌘⇧C` handler recovered `self` with `takeUnretainedValue()` then dispatched to the main queue — would corrupt memory if `onFire` ran on a freed instance. Fixed in Plan 2b by replacing Carbon's `GlobalHotkey.swift` with the KeyboardShortcuts package.

*App (Plan 2b) — every one of these built green and was found only by a human driving the app:*
- **Auto-hide summon-activation race** (`c13a3af`): if the panel was summoned while auto-hide was active, blur and summon could race, causing the panel to dismiss immediately. Fixed by suppressing auto-hide for 0.3s after summon activation.
- **Watcher pinned to the old scripts folder** (`59bec2d`): changing the scripts directory in Settings left `ScriptWatcher` watching the *previous* path, so live reload silently stopped working until relaunch. Watcher setup is factored into `startWatchingScripts()` and re-invoked from a Combine sink on `settings.$scriptsDirectoryPath`. **Any setting that feeds a long-lived system resource must re-point that resource on change** — persisting the value is only half the job.
- **Settings window opened behind everything** (`9ad051b`): an `LSUIElement` agent gets no automatic foreground promotion, so `SettingsLink` opened the window under the active app and looked like a no-op. Needs an explicit `NSApp.activate(ignoringOtherApps: true)`.
- **Disabling a transform made it unre-enableable** (`25b3511`): the Settings Transforms tab rendered from the same enable-filtered list as the palette, so a disabled transform vanished from the UI that was supposed to toggle it — a one-way door. `AppModel` now exposes `allTransformers` (order-applied, enable-*unfiltered*) for Settings; the palette keeps using the filtered `transformers`. **A control surface must never be filtered by the state it controls.**
- **Scripts-folder picker couldn't get home** (`3610f31`, with `57c3d6a`): `NSOpenPanel` hides dotfiles, so once a user navigated away from `~/.config/pastefix/scripts` they could not navigate back to a path inside `~/.config`. Fixed with `showsHiddenFiles = true` plus a **Use Default** button backed by `SettingsStore.resetScriptsDirectoryToDefault()`. Any picker defaulting into a dot-directory needs both.

*App (Plan 2c):*
- **Ad-hoc Debug builds silently run without the hardened runtime.** With `CODE_SIGN_STYLE = Automatic` and no team, `launch.sh` builds are ad-hoc signed, and Xcode disables the hardened runtime for ad-hoc signing ("Disabling hardened runtime with ad-hoc codesigning" in the build log) — so `codesign -dv` shows no `runtime` flag even though `ENABLE_HARDENED_RUNTIME = YES`. Anything that must be verified under the hardened runtime (JavaScriptCore with `allow-jit`, shell spawning) has to be checked on a Developer-ID-signed build: `xcodebuild build … CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=RMKGLPG4K4 CODE_SIGN_IDENTITY="Developer ID Application"`. Verified this way on 2026-09-20: shell and JS transforms both run under the hardened runtime with `com.apple.security.cs.allow-jit`; the entitlement was kept.
- **A synchronized group auto-adds Info.plist to Copy Bundle Resources** (`1692d10`): adding `Pastefix/Pastefix/Info.plist` made Xcode's filesystem-synchronized group treat it as a resource and warn; fixed with a `PBXFileSystemSynchronizedBuildFileExceptionSet` that excludes it from the target. Any non-source file dropped into `Pastefix/Pastefix/` needs the same thought.
- **zsh special parameters in the release script** (`67a341c`): the first draft of `scripts/release.sh` used `local path` and `status` inside `notarize()`; in zsh `path` is the array tied to `PATH` and `status` is read-only, so the function couldn't run a single external command and would have failed only after a full archive + export. Caught in review before the first dry run. In zsh scripts never name variables `path`, `status`, `argv`, `options`, or `cdpath`.
- **`SPUUpdater.delegate` is read-only in Sparkle 2** (`51a561a`, rationale in code comments since `ccedec7`): the delegate has to be passed at `SPUStandardUpdaterController` init, which needs `self`, hence the implicitly-unwrapped `controller` property in `UpdaterController` assigned after `super.init()`. Do not "clean it up" into a `let`.

Note: Sparkle's scheduled (non-user-initiated) update alert brought itself to the front for this `LSUIElement` app with no `SPUStandardUserDriverDelegate` foregrounding fallback needed (verified 2026-09-20 with a 1.0.1 → 1.0.2 scheduled check). User-initiated checks still need the explicit `NSApp.activate` in `UpdaterController.checkForUpdates()`.

## Definition of Done

Before opening or updating a PR:

1. **Tests green:** `swift test` passes; new functions/edge cases have coverage under `Tests/`.
2. **Docs currency:** every new user-facing feature, config key, script contract, or CLI flag is reflected in `README.md` (and `docs/` reference material) **in the same commit** — never wait to be asked.
3. **Invariants intact:** if you changed a Critical Invariant above, update this file and the spec in the same change, and say so explicitly in the PR.
4. **No stray build products** committed; extend `.gitignore` liberally.

### Keeping this file current

When you **significantly expand the project** — a new target, subsystem, script engine, Critical Invariant, or user-facing surface — proactively **propose currency updates to this AGENTS.md** (and the README) to the user, ideally in the same change. A stale AGENTS.md is worse than none: agents load it and follow it as fact. Do not let it rot by assuming "we already have one."

## Specs, plans & reviews layout

**Increment status** — each plan under `docs/plans/` carries a status banner at the top; trust the banner and the git log, not the checkboxes inside it.

| Plan | Scope | Status |
|---|---|---|
| Transform Engine | `PastefixCore` | ✅ merged, PR #1 (`9fc68ee`) |
| 2a — App Core | menu-bar app, hotkey, panel | ✅ merged, PR #2 (`12b3cdd`) |
| 2b — Settings & Prefs | Settings window, rebindable hotkey, live reload | ✅ merged, PR #3 (`4380489`) + 5 follow-up fixes |
| 2c — Auto-update | Sparkle, hardened runtime, release script | 🟡 in review on `feat/auto-update`, PR pending |

Historical reference material for the 2007 and 2019 incarnations is vendored under [`docs/inputs/legacy/`](docs/inputs/legacy/).

- **Design specs:** `docs/specs/YYYY-MM-DD-feature-name.md`
- **Implementation plans:** `docs/plans/YYYY-MM-DD-feature-name.md`
- **Reviews:** `docs/reviews/YYYY-MM-DD-feature-name-review.md`
- These three dated directories are canonical. Do **not** save specs/plans/reviews under `superpowers/` or anywhere else.

## Git & house style

- **Conventional commits** (`feat(core):`, `fix(core):`, `docs:`, `refactor:` …). Commit at natural stopping points, not in one giant dump.
- **Co-credit the agent** in commit trailers (`Co-Authored-By: Claude …` / Gemini / etc.).
- **PR everything that maps to a feature or a bug fix.** Do the work on a branch, open a PR against `main`, and let review run. Commit directly to `main` only for genuinely trivial changes (doc typos, comments, `.gitignore`) or a real emergency — which, for a clipboard app, should be vanishingly rare. Keep `main` releasable.
- Comments explain non-obvious *why*, not *what*; match the surrounding file's density and idiom. No emoji in code or commit subjects. No orphan `TODO`/`FIXME` without a tracked issue.
- No premature abstraction — the codebase is still small.

## Where to look first

- New here? Read the spec end-to-end, then trace a transform: `TransformerRegistry.load()` → a `Transformer.apply(_:)` (native, then `ShellRunner.run` / `JSRunner.run`) → `TransformError` back out.
- `git log --oneline -- <path>` shows recent intent; commit messages are descriptive.
