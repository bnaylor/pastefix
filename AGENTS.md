# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Gemini CLI, etc.) working in this repo. Humans should read [README.md](README.md) and the current design spec under [`docs/specs/`](docs/specs/) first.

## What this project is

Pastefix v2 is a macOS clipboard utility: a menu-bar app with a global hotkey that summons an editable panel, applies text transforms (clean up for IRC/chat, reflow, rich→plain, user scripts, URL cleanup, Markdown links, case conversion), detects URL/JSON content to surface applicable transforms first, and writes the result back to the clipboard. It is the modern Swift rewrite of a 2007 Objective-C app.

The repo has three components:

- **`PastefixCore`** — the transform *engine*, a standalone, dependency-free Swift 6 SwiftPM package (macOS 14+). No UI. It defines a unified `Transformer` protocol over three engines (native Swift, shell, JavaScript), a registry that discovers user scripts, and an FSEvents watcher.
- **`PastefixAppCore`** — the app's *pure model* layer, a second SwiftPM library target (depends on `PastefixCore`). Holds the testable logic that must NOT live in the Xcode target: `ClipboardSnapshot`, `PasteDocument` (undo/redo history), `TransformCoordinator` (bridges engine → document). Unit-tested via `swift test`.
- **`Pastefix`** — the macOS menu-bar app, an **Xcode** target (SwiftUI `MenuBarExtra` + AppKit glue) that links both packages. Global hotkey (rebindable via KeyboardShortcuts, default ⌘⇧C) → floating `NSPanel` editor + ⌘K palette + sidebar → Save writes back to the pasteboard. Includes a Settings window for configurable wrap width, auto-hide-on-blur, custom scripts folder, hotkey rebinding, and per-transform enable/disable + reordering. Sparkle 2 provides auto-update (daily check, Check for Updates… menu item, Settings toggle). Built via `xcodebuild`, verified manually. **Third-party dependencies:** KeyboardShortcuts (sindresorhus) and Sparkle, both app-target only; both packages remain dependency-free.

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

- **Deployment targets differ by layer:** the `Pastefix` app target is **macOS 15.0** (it uses `TextEditor(text:selection:)` / `TextSelection`, macOS 15+, to select detected secrets); `PastefixCore` and `PastefixAppCore` stay at **macOS 14**. Keep package code free of 15-only API.
- Toolchain: Swift 6 (developed on 6.3 / Xcode 26.4), strict concurrency.
- Tests use the built-in **Swift Testing** framework (`import Testing`, `@Test`, `#expect`) — not XCTest.
- Fixture scripts under `Tests/PastefixCoreTests/Fixtures/` are executed directly, so they **must be committed executable** (`git ls-files -s` shows mode `100755`).
- `HistoryStoreTests` construct every store against a fresh directory under `FileManager.temporaryDirectory`, never the real `~/Library/Application Support/Pastefix/history` — the suite is safe to run repeatedly and never touches (or requires cleaning up) a developer's actual clipboard history.
- The Xcode project lives at `Pastefix/Pastefix.xcodeproj` and app sources at `Pastefix/Pastefix/` (note the double nesting). Xcode 16 **filesystem-synchronized groups** auto-add new `.swift` files to the target — do NOT hand-edit `project.pbxproj` to add sources. Linking a *package product* or changing a *build setting* is the exception (a human/controller does it in Xcode or a surgical value flip).
- `xcodebuild -showBuildSettings` reports the **Release** path unless you pass the matching `-configuration Debug`; the product lives in **DerivedData**, not a local `build/`. Use `launch.sh` and stop fighting it.

## Project layout

```
Package.swift                         # swift-tools 6.0, .macOS(.v14), product PastefixCore, NO deps
Sources/PastefixCore/
  Transformer.swift                   # protocol + TransformInput + TransformerSource + TransformError + OutputMode/OutputModeTransformer + TransformCategory.richText; TransformCategory.presets last in builtinOrder; TransformLimits.defaultMaxInputBytes/defaultTimeout back maxInputBytes/timeout
  ByteLimit.swift                     # ByteLimit.describe(_:) renders a byte cap in binary units for banners ("64 KB", "256 KB", "1 MB")
  Deadline.swift                      # Deadline.run(seconds:priority:_:) — the one sanctioned deadline race: try Task.checkCancellation() first, then returns to the caller at the deadline whatever the body does and always cancels it (abandons, does not stop)
  RegexPreset.swift                   # RegexPreset model (Codable/Sendable/Identifiable): pattern/replacement/four flags, regexOptions, compile(), expandEscapes (\n/\t real, every other backslash DOUBLED for the ICU template, \$ kept); explicit tolerant init(from:) — only id/name/pattern required, every flag decodeIfPresent
  Markdown/
    MarkdownHTML.swift                 # Markdown -> HTML fragment (AttributedString(markdown:) walked by presentationIntent)
    MarkdownFromRich.swift             # RTFD -> GitHub-flavoured Markdown (headings, lists, tables flattened, images dropped)
  Native/                             # native Swift transforms (pure String -> String)
    RichToPlain.swift                 #   builtin.richtoplain  (order 10, requiresRichInput, category richText)
    RichToMarkdown.swift              #   builtin.richtomarkdown (order 11, requiresRichInput, category richText)
    MarkdownToRich.swift              #   builtin.markdowntorich (order 12, OutputModeTransformer .renderedMarkdown, kinds [markdown], category richText)
    Transliterate.swift               #   builtin.transliterate (order 20)
    WrapReflow.swift                  #   builtin.wrapreflow   (order 30, init(width:))
    WhitespaceCleanup.swift           #   builtin.whitespace   (order 40)
    URLCleaner.swift                  #   builtin.urlclean     (order 50, kinds [url])
    MarkdownLink.swift                #   builtin.markdownlink (order 60, kinds [url]) + TitleFetcher (the engine's only network access)
    CaseConvert.swift                 #   builtin.case.{camel,snake,kebab,constant} (70–73)
    JSONActions.swift                 #   builtin.json.{pretty,minify,escape} (80–82)
    Encoders.swift                    #   builtin.{base64,url,html}.{encode,decode} (90–95)
    JWTDecode.swift                   #   builtin.jwt.decode (96), never verifies the signature
    ColorLiteral.swift                #   ColorLiteral: CSS/SwiftUI colour literal parse + format, sRGB 0…1
    ColorConvert.swift                #   builtin.color.{hex,rgb,hsl,swift} (100–103)
    RedactSecrets.swift               #   builtin.redactsecrets (order 110, category privacy, kinds [secret])
    RegexPresetTransformer.swift      #   RegexPresetTransformer: preset:<uuid> id, .preset(id) source, category presets, order 900 (registry-assigned, name-sorted); 256 KB input cap (checkInputSize, applied by apply AND preview), 2 MB output cap, 3 s deadline checked in-block via enumerateMatches(options: [.reportProgress]) — apply runs the deadline check under Deadline.run, the only sanctioned deadline race; replace returns (output, matches) so the public preview(_:preset:deadline:) wrapper is one pass under one deadline
  Detection/
    ContentKind.swift                 # url | json | color | jwt | base64 | percentEncoded | htmlEntities | markdown | secret (+ displayName)
    ContentDetector.swift             # detect(_:) -> Set<ContentKind>, 1 MB guard; detect(_:secrets:) takes an already-computed scan so a caller needing the ranges too scans once
    SecretDetector.swift              # SecretKind, SecretMatch, scan(_:) (256 KB guard) + entropy(_:); SecretRedactor.redact(_:matches:)
    MarkdownDetector.swift            # looksLikeMarkdown(_:) heuristic; CRLF/CR normalised to LF first, capped at 64 KB / 400 lines
    URLFinder.swift                   # internal http(s) link ranges (NSDataDetector); 256 KB maxBytes cap (matches SecretDetector), enumerateMatches(options: [.reportProgress]) so a cancelled Task.isCancelled stops the scan early and a partial list is only ever returned to a caller that discards it
    HTMLEntities.swift                # shared entity decode table (HTML Decode + Markdown-link title parser)
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
  DetectionResult.swift               # DetectionResult.compute(_:) pairs SecretDetector.scan + ContentDetector.detect(_:secrets:) in one pass; DetectionState .pending/.complete(DetectionResult)
  DetectionScheduler.swift            # DetectionScheduler: @MainActor single-slot off-main detection lane — one Task.detached scan at a time, a request mid-scan cancels it and becomes the sole waiting request; the slot is hard across cancelAll(), which cancels the running scan's task but keeps the slot until it actually finishes (undelivered), because only URLFinder observes cancellation
  PasteDocument.swift                 # origin + history/cursor undo/redo/refresh + outputMode (default .plain, reset on refresh); never scans — carries DetectionState .pending/.complete(DetectionResult) + detectionRevision, bumped on init/push/undo/redo/refresh (refresh carries the revision forward past its prior value rather than resetting to 0, so a pre-refresh result can't be mistaken for a post-refresh one); applyDetection(_:revision:) installs a result only for the current revision
  TransformCoordinator.swift          # apply(transformer, to: document) + isEnabled; refuses input over transformer.maxInputBytes before calling apply — measured on input.richRTFD ("X is limited to N of rich text.") when transformer.requiresRichInput, on input.text ("X is limited to N of text.") otherwise; runs apply under Deadline.run(seconds: transformer.timeout), mapping .timeout/CancellationError to "The transform timed out."/"The transform was cancelled."; sets document.outputMode from an OutputModeTransformer, reports .applied even when text is unchanged; always calls pushState (even on equal text) so detection resyncs after a manual setWorking edit
  TextRangeClamp.swift                # remap(_:from:to:) -> Range<String.Index>?: re-expresses an editor selection at the same UTF-16 offsets in a replaced buffer (nil when they don't exist there), so an apply/undo/redo carries the caret instead of dropping it — a stale String.Index traps
  RichOutputRenderer.swift            # @MainActor render(markdown:) -> RichOutput{html,rtf}: MarkdownHTML.render then NSAttributedString(html:) -> RTF; <img> stripped from the RTF conversion input only
  MarkdownPreview.swift               # @MainActor attributedString(markdown:) -> NSAttributedString for the panel's Preview toggle: MarkdownHTML.render -> RichOutputRenderer.htmlForRTF (<img> stripped) -> stylesheet -> NSAttributedString(html:) -> foreground colours stripped except .link runs; 16 KB / 200 `<li>` caps return a notice string (the importer is main-thread-only, so work, not just bytes, has to be capped)
  SettingsStore.swift                 # UserDefaults persistence (wrap width, auto-hide, sidebar, scripts folder, per-transform enable/order, historyEnabled, historyMaxItems)
  TransformOverrides.swift            # per-transform enable/disable + drag-reordering
  PaletteOrdering.swift               # applicable-first stable partition on top of TransformOverrides
  FuzzyMatch.swift                    # shared fold + tiered match (prefix/word-start/subsequence) + highlight ranges; fold-once `tier` for ranking-only callers
  TransformSearch.swift               # ⌘K palette ranking, delegates matching to FuzzyMatch
  SidebarGrouping.swift               # groups transforms into sidebar sections by category (built-in order, then custom, then Scripts)
  History/
    HistoryItem.swift                 # Codable item: text/rich/image representations, source app, byteCount, kind
    HistoryStore.swift                # @MainActor ObservableObject: cap+budget enforcement, de-dup, index+blob persistence, quarantine; imageURL(for:) hands out the id-derived blob path for off-main reads
    HistorySearch.swift               # fuzzy ranking over items via FuzzyMatch (image-only items match "image <app>")
    HistoryFormatting.swift           # previewText/relativeAge/byteLabel pure helpers for the overlay row
  Capture/
    CaptureContext.swift              # CaptureContext (sourceBundleID/Name, recentBundleIDs) + CaptureFilter protocol (shouldRead/shouldCapture)
    ConcealedTypeFilter.swift         # moved from the app target; ignores context
    AppExclusionFilter.swift          # rejects if sourceBundleID or any recentBundleIDs entry is excluded (case-insensitive)
    ExclusionSeeds.swift              # ExclusionSeeds.passwordManagers — the seeded bundle-id list
    RecentApps.swift                  # pure windowing helper (Entry, window(entries:now:window:), trimmed(_:now:retention:))
    PendingImage.swift                # resolve(): what a capture keeps when its deferred TIFF->PNG conversion fails or lands over budget (#32)
Tests/PastefixAppCoreTests/           # swift-test suites for the model; HistoryStoreTests write to FileManager.temporaryDirectory, not the real Application Support directory
Pastefix/                             # the Xcode app (KeyboardShortcuts + Sparkle dependencies only)
  Pastefix.xcodeproj                  # ENABLE_APP_SANDBOX = NO, ENABLE_HARDENED_RUNTIME = YES
  launch.sh                           # build Debug + open the .app
  Pastefix/                           # app sources (system glue only, no unit tests)
    PastefixApp.swift                 # @main MenuBarExtra + NSApplicationDelegateAdaptor; owns HistoryStore + PasteboardMonitor + FrontmostAppTracker, menu-bar Clipboard History toggle + pause glyph, second hotkey, flush on terminate
    AppModel.swift                    # @MainActor ObservableObject: registry+document+clipboard+history; load(_:)/copyBack(_:), historyOverlayRequested
    HotkeyName.swift                  # KeyboardShortcuts recorder + display helper; summonPastefix (⌘⇧C) + summonHistory (⌘⇧V)
    FrontmostAppTracker.swift         # @MainActor tracker fed by NSWorkspace.didActivateApplicationNotification; context(window:) -> CaptureContext (source app determined before the read, Critical Invariant 12)
    SettingsView.swift                # SwiftUI Settings window (General/Privacy/Snippets/Presets/Shortcut/Transforms tabs); Privacy has the History section (moved from General) + Excluded Apps list + two-option Clear dialog, Snippets has Accessibility status + per-pin title/recorder/Unpin rows (shortcutValidation blocks combos already bound to another snippet or to the summon shortcuts, and the Shortcut tab validates against snippets in turn), Presets tab delegates to PresetsSettingsView, Shortcut a second recorder
    PresetsSettingsView.swift         # Presets tab: preset Picker + (+/−) above a full-width editor (name/pattern/replacement/four flags) bound to a draft copy, Save/Revert, live preview (RegexPresetTransformer.preview, 200 ms debounce, 16 KB sample cap, 1 s deadline); + makes an UNSAVED draft (only Save writes to the store), Save disabled while the pattern is empty/doesn't compile or the name is blank, dirty drafts marked • and guarded by a discard alert
    ClipboardBridge.swift             # NSPasteboard <-> ClipboardSnapshot; write(text:richRTFD:imagePNG:) for multi-representation copy-back
    PanelController.swift             # floating resizable NSPanel host (+ sidebar-driven resize, sidebar-aware minSize)
    PanelMetrics.swift                # panel/sidebar/palette sizes shared by SwiftUI and AppKit
    PanelView.swift                   # editor + action bar + full-panel ⌘K/history overlay host + sidebar column + Esc owner; toolbar pin button/⌘⇧P opens a title popover (pinCurrentBuffer); Preview toggle (⌘⇧M) swaps the editor for MarkdownPreviewView, 150ms-debounced re-render on buffer/undo/redo change, Esc closes the preview before Cancel
    MarkdownPreviewView.swift         # NSViewRepresentable read-only, selectable NSTextView (isEditable false) hosting MarkdownPreview's rendering for the Preview toggle
    CommandPaletteView.swift          # ⌘K overlay: TransformSearch-ranked list, type/↑↓/↵/Esc
    PasteboardMonitor.swift           # polls changeCount 2x/sec; builds CaptureContext from FrontmostAppTracker before each read, refreshes it after; two-stage CaptureFilter chain (ConcealedTypeFilter + AppExclusionFilter) (Critical Invariant 12); TIFF->PNG conversion runs detached, re-checking change count + filters on the way back (#32); TIFFConversionSlot is the process-wide lane (one decode, one waiter) and mints the generation numbers
    HistoryOverlayView.swift          # ⌘⇧V/⌘Y overlay: HistorySearch-ranked list, thumbnails (blob read + decode off-main, installed by item id even if the requesting row is gone; an undecodable blob is logged and remembered, not retried), ↵/⌘↵/⌘⌫/⌘P/⇧↵/Esc; Pinned/History sections
    SnippetPaster.swift               # Accessibility-gated ⌘V poster: waits for modifiers released + target frontmost, .privateState CGEventSource, generation-superseded
    SnippetHotkeys.swift              # per-pin KeyboardShortcuts.Name("snippet-<uuid>"); sync() registers/removeHandler as pins come and go
    SidebarView.swift                 # SidebarGrouping-driven, category-sectioned transform list
    UpdaterController.swift           # Sparkle SPUStandardUpdaterController wrapper (+ Debug feed override)
    Info.plist                        # SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks, SUScheduledCheckInterval
    Pastefix.entitlements             # com.apple.security.cs.allow-jit only; NEVER app-sandbox
scripts/release.sh, scripts/ExportOptions.plist   # release pipeline (see docs/RELEASING.md)
docs/specs/  docs/plans/  docs/reviews/   # dated design docs (see below)
```

## Critical invariants — DO NOT BREAK

These are load-bearing; most were established the hard way (see "Things that have bitten us").

1. **Transforms are single-purpose and composable.** Each transform does exactly one job. `Transliterate` strips/normalizes non-ASCII and **never touches whitespace** — collapsing spaces is `WhitespaceCleanup`'s job. Do not merge responsibilities to make one transform "smarter."
2. **A transform never corrupts the working buffer.** Timeout, non-zero shell exit, or a JS exception surface a typed `TransformError`; the caller keeps the prior text. `TransformError` cases (`richInputUnavailable`, `timeout`, `nonZeroExit(code:stderr:)`, `scriptFailed(String)`, `invalidInput(String)`) are `Equatable` and consumed by tests — don't rename or repurpose them.
3. **Rich content travels as RTFD `Data?`, not `NSAttributedString`.** `TransformInput` must stay `Sendable` under the `async` protocol; only `RichToPlain` reconstructs the attributed string from `richRTFD`.
4. **`PastefixCore` and `PastefixAppCore` have ZERO external dependencies.** KeyboardShortcuts and Sparkle live in the app target only — never the engine or model layer. Adding a package dependency to `PastefixCore` or `PastefixAppCore` is a design change, not a convenience.
5. **Shell contract:** working text on **stdin → stdout**; the script file is executed directly so its shebang is honored; minimal scrubbed env; cwd = the script's directory. Drain stdout **and** stderr **concurrently** (`async let`) before `waitUntilExit()` — sequential draining deadlocks on >64KB stderr. The timeout is a **hard bound**: the child runs in its own process group and gets SIGTERM then SIGKILL after a short grace. `kill(-pid)` always uses the child's own positive PID — it must never be able to become `kill(0)` (caller's group) or `kill(-1)` (broadcast). `.nonZeroExit` stderr is truncated to a bounded tail.
6. **JS contract:** the script defines `function transform(text)`, run in a **fresh `JSContext` per call**; exceptions (read via `context.exception`) or a non-string return are errors. The eval/timeout race is guarded so the continuation resumes **exactly once**. JavaScriptCore cannot be interrupted, so a runaway script is abandoned best-effort on timeout (its thread runs until process exit) — this is documented, not a bug to "fix" by weakening the timeout.
7. **FSEvents lifetime:** the stream owns a **retained `WatcherContext` box** (via `passRetained`, balanced by the context `release` callback) — never `passUnretained(self)`, which is a use-after-free. `ScriptWatcher.stream` access is `NSLock`-guarded; `deinit` calls `stop()`.
8. **Transformer identities are stable and typed:** `builtin.<name>`, `preset:<uuid>`, `shell:<filename>`, `js:<filename>`. Built-ins occupy orders 10–12/20/30/40/50/60/70–73/80–82/90–96/100–103/110; orders gain `900 (presets, name-sorted)` before `1000 (scripts)` — discovered scripts default to 1000; the registry sorts by `(order, name)` and returns only enabled transforms. Missing/unreadable script dirs are tolerated (built-ins still load).
9. **The app is NON-SANDBOXED (`ENABLE_APP_SANDBOX = NO`).** By design (direct-download, notarized). The sandbox would block reading `~/.config/pastefix/scripts/` and executing shell/JS scripts — i.e. it kills the entire user-scripts pipeline, the heart of the product. Xcode's app template re-enables the sandbox on a whim; if you regenerate or reconfigure the target, re-verify it stays off (`codesign -d --entitlements - <app>` must not show `com.apple.security.app-sandbox`).
10. **A slow transform must not lose the user's edit.** `AppModel.apply` is gated by `isApplying`: while an async transform (shell/JS up to 3 s; a self-bounding native transform such as `MarkdownLink` up to ~4 s) runs, the editor, palette, and sidebar are disabled so nothing mutates the document underneath the in-flight apply, and the result can't overwrite a newer edit. The apply completion also drops its result outright if the session ended meanwhile (`document == nil` after Save/Cancel/auto-hide), so a finished transform can never resurrect a dismissed panel; results are also tagged with a session generation, so a result from a dismissed session cannot land in a newer one. Don't remove the gate without a replacement that closes the same race.
11. **Hardened runtime + notarization are release requirements, and the Sparkle key is the root of trust.** `ENABLE_HARDENED_RUNTIME = YES` with `Pastefix.entitlements` carrying `com.apple.security.cs.allow-jit` (JavaScriptCore) and never `app-sandbox`. Sparkle lives only in the app target. The EdDSA private key in the maintainer's login keychain signs every update; a release signed with a different key is rejected by every installed copy, so the key is backed up and never regenerated, and `scripts/release.sh` refuses to ship if the keychain key does not match `SUPublicEDKey`. The `CFBundleVersion` Sparkle compares is `git rev-list --count HEAD` at release time — never hand-edit it in the pbxproj.

12. **Clipboard history never records items marked concealed/transient/auto-generated (including the legacy nspasteboard.org markers), never stores or deletes anything outside the owner-only history directory (blob paths derive only from the item id), and every capture passes the two-stage `CaptureFilter` chain (`shouldRead` on declared types before any content is read, `shouldCapture` on the real candidate after the change count is re-checked) — new capture sources, filters, or storage paths must keep all three.** The source app is determined before the read from a notification-fed tracker (`FrontmostAppTracker`), and every app frontmost within the poll window is checked against the exclusion list; both filter stages receive that context.

## Patterns and conventions

- **Native transforms** are pure `String -> String` (or `NSAttributedString -> String` for rich→plain) behind the `async throws` protocol. Keep the pure logic in a `static` helper so it's testable without the async surface.
- **New built-in transform** → new file in `Native/`, conform to `Transformer` with a `builtin.<id>` id and `.builtin` source, register it in `TransformerRegistry.load()` with an explicit order, and add a fixture-driven test suite (cover the nasty inputs: smart quotes, dingbats, CJK, wrap boundaries).
- **New script engine or metadata key** → extend `ScriptMetadata` / the runner protocol symmetrically with shell and JS; keep the magic-comment format (`# pastefix: key = value`, keys scanned in the first 30 lines, comment lead-ins `#`/`//`/`*`/`/*` tolerated).
- **Tests** live under `Tests/PastefixCoreTests/`, one suite per component, no mocking framework — real fixture scripts and real `NSAttributedString`/`JSContext` where needed.
- **Concurrency:** favor `async`/`async let` and small `@unchecked Sendable` lock boxes (see `Debouncer`, `ResumeGuard`) over ad-hoc threads; if you write `@unchecked Sendable`, the synchronization must actually exist.
- **Network in a transform** happens only through an injected protocol (`TitleFetcher`) with a hard timeout and a byte cap, and the transform races it against its own bound so a hung fetcher cannot hang the app; `MarkdownLink.timeout` (`fetchTimeout + 2`) still gives the coordinator's `Deadline.run` margin over the fetch race it wraps. Tests inject a stub; no test opens a socket.
- **Content kinds:** a transform that is *meant for* a kind sets `applicableKinds`; the palette promotes it, never hides others. Detection heuristics live only in `ContentDetector`.
- Every detector regex is bounded and has a timing test; `SecretDetector` stops at 256 KB, `ContentDetector` at 1 MB, and `URLFinder` at 256 KB — measure before raising any of them.
- User regexes run under a 256 KB input cap, a 2 MB output cap (a zero-width match with a long replacement amplifies without bound — measured 1.2 GB RSS), a 3 s deadline, and `enumerateMatches(options: [.reportProgress])` — without `.reportProgress` the deadline is never checked inside a backtracking attempt (measured 10.9 s unthrown). Never "simplify" it to `[]`. The deadline itself is `Deadline.run`, not a hand-rolled task-group race: a group awaits its children, so it cannot cut a running scan loose (sleeper at 3.2 s, caller unblocked at 10.9 s under the old race). `RegexPreset.expandEscapes` emits an ICU *template*, which un-escapes a second time, so every backslash that must reach the output is emitted doubled — assert replacement behaviour through `apply`, never on the template.
- **Session text is scanned off the main actor.** `PasteDocument` never scans; every discrete event (summon, load, refresh, push, undo, redo) marks detection pending and bumps `detectionRevision`, `AppModel.requestDetection()` hands `(working, revision, sessionGeneration)` to `DetectionScheduler`, and the result lands only if both still match. Never call `SecretDetector`/`ContentDetector` on the main actor for session text; the badges are simply absent while pending.
- **Every transform declares `maxInputBytes` and `timeout`** (defaults in `TransformLimits`: 1 MB, 3 s); the coordinator enforces both. A new transform whose cost is superlinear, or that calls an uninterruptible Foundation API, lowers its cap (Markdown → Rich Text is 64 KB for the pipeline `MarkdownPreview` caps at 16 KB); one that can loop checks `Task.isCancelled`. `URLFinder` has its own 256 KB cap, so anything built on it inherits it. A transform whose `requiresRichInput` is true (RichToPlain, RichToMarkdown) reads `TransformInput.richRTFD`, never `.text`, so the coordinator measures its cap against the rich bytes, not the plain-text length — a 4 MB RTFD cap either one declares.
- **`Deadline.run` is the only sanctioned deadline race.** It returns to the caller at the deadline whatever the body does and cancels the body; it abandons, it does not stop. A structured task-group race is not a bound (it awaits its children). Input caps bound the work; the deadline bounds the wait.
- **Expensive capture work happens off the main actor, and everything it depended on is re-checked when it lands.** The TIFF→PNG conversion (#32) runs in a detached task over `Data` alone; the capture is made from the completion, back on the main actor, where the change count is re-checked and the stage-2 filters re-run over the earlier types unioned with those declared now (`setData` does not bump the change count, and the conversion window is far wider than the read's). Attribution stays the pre-conversion sample — the source app is determined before the read — while the exclusion check gets the widened recent-app set. Conversions go down one process-wide lane (`TIFFConversionSlot.shared`) so large decodes can't stack: one superseded before it starts is skipped, one already running finishes (`NSBitmapImageRep` has no cancellation point, so cancelling the wrapper task bounds nothing — don't mistake it for a bound). The lane holds a *single waiter*, not a queue: a second arrival displaces the one waiting, because a queue bounds concurrent decodes while leaving every queued block holding its own source TIFF. It is shared rather than per-monitor because a rebuilt monitor would otherwise add a second lane. Generations are minted by the lane for the same reason — one monotonic counter across instances. A failed or over-budget conversion falls back to the text (`PendingImage.resolve`), and every drop is logged at `.notice`, since `.debug` is not persisted and is compiled out of release. Any new off-main capture step owes the same three things: a supersession rule, the change-count re-check, and the filter pass.
- **Poll the pasteboard on change, not on the tick.** `PasteboardMonitor` reads `NSPasteboard.general` at most once per `changeCount` change — never on a bare timer tick with no change — and reads rich content (RTFD) only when a rich type (`.rtf`/`.rtfd`/`.html`) is actually declared, the same Plan 2a lesson `ClipboardBridge` already relies on. Any new capture source must read the same way: sample types first, read once, and never assume a tick means new content.
- **Capture filters get a `CaptureContext` built before the read and refreshed after it.** Attribution comes from the tracker's newest activation; exclusion checks every app the tracker saw within the poll window *plus* the live `NSWorkspace.frontmostApplication` id (unioned into `recentBundleIDs` as a fail-closed cross-check, never used for attribution). Don't remove either half.
- Accessibility is requested only to post ⌘V (`SnippetPaster`); Pastefix never installs an event tap or observes keystrokes — keep it that way. A ⌘V is posted only after shift/control/option/command are released and no Pastefix window is key, and the target is verified frontmost; on any doubt, copy-only.
- `OutputModeTransformer` is the only channel by which a transform influences Save. Render at save time from the live buffer; never cache rendered output on the document. Rendered HTML goes through the URL-scheme allowlist, and the RTF conversion input has `<img>` stripped so Save never touches the network.
- The preview shares the RTF pipeline's `<img>` stripping (`RichOutputRenderer.htmlForRTF`) — the importer is WebKit-backed and must never be handed an `<img>`
- **Browsing UIs stay dumb:** the ⌘K palette reads `enabledTransformers()` (applicable-first) and the sidebar reads `browsableTransformers()` (plain user order, no detection promotion, so a browse surface doesn't reshuffle with the clipboard); both render whatever a pure AppCore function hands back — ranking (`TransformSearch`), grouping (`SidebarGrouping`), and applicable-first ordering (`PaletteOrdering`) are pure functions in `PastefixAppCore`, not view logic. A view should never re-sort or re-filter the list itself.

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

*Engine (Plan 3):*
- **NSDataDetector over-matches trailing punctuation and the URL must be rebuilt from the trimmed text** (`763dc8d`): the detector's `match.url` includes a trailing `:` `'` `?` or unbalanced `)`; only its scheme is trustworthy. `URLFinder` takes the scheme from the detector and builds the URL from the trimmed range so `url` always corresponds to `original`. Tests must use inputs the detector genuinely over-matches, or the trimming loop is untested.
- **Dictionary iteration order is not a spec** (`29c1d02`): entity decoding iterated a `Dictionary`, so `&amp;lt;` decoded differently per process launch. Ordered replacement lists must be arrays.

- **HTML-escaped separators** (`1f37313`): links copied out of email or HTML source carry `&amp;` between query parameters, so `URLComponents` parses the second parameter as `amp;utm_medium` and `URLCleaner` stripped only the first tracker. `&amp;` is now normalised to `&` before stripping (and that normalisation alone counts as a change). No fixture caught this — it surfaced only when the maintainer pasted a real newsletter link. Test with text that was actually copied from a rendered page, not with hand-written URLs.

Also caught in review on `29c1d02`: a page truncated at the byte cap mid-character fell back to Latin-1 and garbled titles; `decodeHTML` retries UTF-8 after dropping up to 3 trailing bytes.

*App (Plan 3):*
- **Save during an in-flight apply wrote the pre-transform text** (`f254e7d`): `MarkdownLink` was the first transform that can run for seconds, and it exposed that `AppModel.apply`'s completion assigned its result unconditionally — Save/Cancel/auto-hide during the apply ended the session, then the late completion either resurrected the dismissed document or left `isApplying` stuck for the next summon, while Save itself had already copied the untransformed buffer. The completion now drops its result when `document == nil`, `endSession()` clears `isApplying`, and Save/Undo/Redo/Refresh are disabled (with a spinner in the palette) while an apply is in flight. Cancel stays enabled. **Any UI affordance that commits state needs the same treatment as the editor the moment a transform can outlast a click.**

*App (Plan 4):*
- **A fixed-size, non-resizable `NSPanel` ignores SwiftUI min-width changes** (`297a618`): `PanelView`'s `minWidth` grew from 560 to 780 when the sidebar opened, but `PanelController` created the panel without `.resizable` at a hardcoded 640×460 — AppKit never grew the frame, so the sidebar just squeezed the editor into the existing width. Fixed by giving the panel `.resizable`, a sidebar-aware `minSize`, and an explicit `setSidebarVisible(_:width:)` driven from a Combine sink on `settings.$showSidebar`. **Any setting that changes the panel's size must resize it in AppKit, not just change a SwiftUI `frame` — the window manager, not SwiftUI, owns the actual frame.**
- **A `.frame(maxWidth:)` outside a plain `Button` does not extend its hit area** (`297a618`): the sidebar rows sized only the `Text`, so a `Button` styled `.plain` was clickable just over the glyphs of the transform name, not across the row. Fixed by moving the `.frame(maxWidth: .infinity)` and `.contentShape(Rectangle())` inside the button's label. A `Button`'s tap target is exactly its label's shape — sizing has to happen there, not on a modifier chained after the button.
- **⌘K Return applied the first result, not the highlighted row** (`7f67d41`): the submit handler closed over a render-time local index, so arrowing down moved the highlight but Return still applied result 0. It survived every manual check because those all happened to press Return on the first result. SwiftUI retains a submit/key handler across re-renders; a retained handler must read `@State` at call time (it resolves through its storage box and is always current) and never close over a value computed in `body`.

*Engine (Plan 5):*
- **Hand-written parsers must reject what Foundation accepts** (`15a2b7e`): `Character.isHexDigit` is true for fullwidth digits that `UInt8(_:radix:)` rejects, and `Double("nan")` survives `min`/`max` clamping — both crashed on pasted text until guarded (`isASCII`, `isFinite`).
- **`JSONSerialization.data(withJSONObject:)` raises an ObjC exception, not a Swift error** (`e2b0807`): `-1e400` parses to `-inf`, and writing it aborts the process past any `try`; check `isValidJSONObject` (allowing safe fragments) before writing.
- **Moving a helper changes its input size** (`767e34f`): the entity decoder converted each match's `NSRange` back to a `String.Index` range, which is O(offset) per match — quadratic, and completely harmless while its only caller was a `<title>` a few dozen characters long. Pointing it at the working buffer for "HTML Decode" made 1 MB of numeric references freeze the panel for ~25 s. Fixed by splicing on an `NSMutableString` with the regex's own UTF-16 ranges (≈35× faster; ~0.7 s per MB). Still superlinear because each splice shifts the tail — a truly linear version appends into a fresh string — and native transforms have no input cap (#29). When a helper moves to a new call site, re-check its complexity against the new input bound.

*Clipboard history (Plan 6) — the persistence layer and the capture path each needed two review rounds; all three blockers were invisible to a green build:*
- **Blob names trusted from `index.json`** (`df73481`): reads and deletes used the stored file name, so a crafted `"imageFile": "../x"` gave arbitrary read (onto the clipboard) and delete. Blob paths derive only from the item id; anything else is treated as missing at load.
- **Deletes weren't durable** (`df73481`, `44d0881`): `remove`/`clear`/cap trims only scheduled the debounced index write, so a crash inside 250 ms resurrected cleared items as text. Deletions flush synchronously; record stays debounced.
- **Quarantine sweep ate the evidence** (`44d0881`): after quarantining a corrupt index the orphan sweep deleted every blob it referenced. Skip the sweep on that launch; `clear()` also removes quarantine files.
- **Store built with the default cap, user cap applied later** (`bf34f73`): init trimmed to 200 on every launch for anyone above it. Construct with the configured limits; clamp and debounce cap changes from Settings (`@Published` emits pre-clamp, and stepper autorepeat evicts per step).
- **Types sampled after the content read** (`bf34f73`, `1ea4d06`): a concealed marker landing mid-read could record a password under the next item's types. Sample types first, re-check `changeCount` after the read, and run the stage-2 filter on the union of pre- and post-read types. Polling still can't honour a marker an app adds after our tick has read the item.
- **TIFF byte heuristic rejected the wrong images** (`2da9a1a`): "PNG ≤ 4× TIFF" is false for screenshots (15–40×). Gate on header pixel count. The decode and re-encode it still cost then ran on the main actor (0.4-1.3 s, during menu tracking, for a PNG the budget often discarded) and moved off it in #32 — with the change-count re-check and the stage-2 filter pass repeated after the conversion, because the window is now wide enough for both answers to change.
- **Fuzzy folding per character per keystroke** (`3c64bbb`): ~140 ms per keystroke at 200 × 4 KB items. Fold each haystack once for the tier; per-character matching only on the ≤160-char preview; the overlay caches results in `@State`.
- **⌘⌫ is a field-editor binding** (`0966c97`): `onKeyPress` never sees it inside a focused `TextField`; use a hidden key-equivalent `Button`, as ⌘K/⌘Y already do.
- **Serialising the work does not bound the resource** (PR #46 review): the first `TIFFConversionSlot` ran one decode at a time by dispatching every arrival onto a serial queue — which removed the concurrent *bitmaps* and kept every queued block holding its own source TIFF (up to ~100 MB at the pixel ceiling) until it was dequeued and skipped. At a 0.5 s poll and ~1.3 s per conversion a burst therefore kept three TIFFs alive waiting for one decode: the same peak, relocated. A lane that means to bound bytes holds a single *waiter* and displaces it, rather than queueing behind it. Write the bound you actually enforce in the comment, and check it against the resource the comment names.
- **A per-instance lane is not a lane** (PR #46 review): `rebuildMonitor()` (any edit to the exclusion list) constructs a fresh `PasteboardMonitor`, so the slot, its queue and its generation counter were all replaced — editing settings mid-conversion ran the outgoing monitor's decode alongside the incoming one's, and `stop()` only skips a conversion that has not started. Anything whose whole purpose is a process-wide bound has to outlive the object that happens to use it; the generation counter went with it, since two counters starting at 0 collide.
- **`.debug` is not "logged"** (PR #46 review): the drop sites that exist so a lost capture is never silent logged at `.debug`, which is not persisted and is compiled out of the default release stream — a user asking why a screenshot never reached history would have had to reproduce it twice, the second time after `log config --mode level:debug`. User-visible data loss is `.notice` or louder; keep `.debug` for the genuinely incidental, as the orphan-blob sweep does.
- **A grey placeholder is not a report** (PR #46 review): a thumbnail whose blob would not decode left the row on the placeholder and said nothing anywhere. `HistoryStore` sets `imageFile` only after an atomic write, so the failure means missing or corrupt — not slow, and not worth retrying. It is logged once and the id remembered for the session, which is the difference between an end state and a dead end.

*Sensitive-app exclusion (Plan 7):*
- **Activation notifications lose races** (`49c718b`): the tracker only knows activations already delivered, and a tick holds the main thread, so the "refreshed" post-read context can't learn anything new. Cross-check the live frontmost id into the reject set; say plainly in comments what a second sample can and cannot see.
- **A settings value written as the wrong `defaults` type is silently ignored** (automated pass): JSON-backed settings are stored as `Data`; `defaults write -string` never reaches the app. Test hooks must write `-data <hex>`.
- **SwiftUI `Form` puts a titled `Stepper`'s label in the leading gutter** (`73604f8`): use `HStack { Text; Spacer; Stepper("").labelsHidden() }`; and four text buttons don't fit a 460 pt settings pane — use +/− controls.

*Markdown ↔ rich text (Plan 8):*
- **Rendered HTML is an injection surface** (`385ab02`, `e2a463b`): Foundation escapes raw HTML in Markdown, but `[x](javascript:…)` and `![x](data:…)` reach `href`/`src` verbatim. Allowlist schemes (http/https/mailto/relative, not `//host`); fall back to escaped text.
- **AppKit's HTML importer fetches remote images** (`197bfb3`): `NSAttributedString(html:)` is WebKit-backed, so converting to RTF at Save would hit any `<img src>` URL. Strip `<img>` from the conversion input; the pasteboard HTML keeps them.
- **RTF drops `headerLevel`** (`cf781d4`): headings only survive a clipboard round trip via size/weight; measure against the dominant size of *non-bold* text or a heading-only document becomes its own baseline. WebKit writes numbered markers as `\t1\t` (no period).
- **A list-marker stripper that accepts bare numbers eats content** (`63ce0c1`): "2024 was a year" → "was a year" on the RTFD path where markers are already gone. Strip only the tab-delimited form.
- **`"\r\n"` is one Swift `Character`** (`cf781d4`): splitting on `"\n"` never splits CRLF text; normalise first.
- **Unbounded regex quantifiers on user text** (`4935e9d`): `\[[^\]]+\]\([^)\s]+\)` over a 64 KB line of `[` backtracks for 1.6 s on the main actor. Bound quantifiers and cap per-line scans.

*Pinned snippets (Plan 9) — posting ⌘V into other apps is the riskiest thing the app does; almost every finding was about doing it *only* when safe:*
- **Held hotkey modifiers combine with a posted ⌘V** (`db7e783`): `onKeyUp` fires while ⌃⌥⇧ are still down and a combined-state event source merges live hardware modifiers, so a snippet hotkey could paste as ⌥⌘V (Finder: Move Items Here). Build from `.privateState`, Command only, and wait for modifiers to release.
- **`deviceIndependentFlagsMask` includes Caps Lock** (`6428d9b`): waiting on it meant no hotkey ever pasted with Caps Lock on. Wait on shift/control/option/command only.
- **Never post blind** (`db7e783`, `1579f92`): nil/terminated targets, refused activation, Pastefix as target, or a key Pastefix window (the non-activating panel holds key focus while inactive) all mean copy-only. Verify the frontmost pid in the same loop that waits for modifiers.
- **Activate the target before hiding the panel** (`6428d9b`): cooperative activation is only granted while we are the active app; hiding first turns ⇧↵ into copy-only.
- **`paste(text: "")` for an image row deletes the target's selection** (`1579f92`): every paste path must check `hasText`; images copy back instead.
- **Hard-coded key code 9 is only "v" on QWERTY** (`1579f92`): on Dvorak it is ⌘K. Resolve the key code against the current layout.
- **Unpin at the cap was a delete** (`fd9ffac`): an unpinned item kept its old `capturedAt` and was the next eviction victim. Unpinning re-inserts it as newest.
- **Ad-hoc Debug signatures lose TCC grants on every rebuild** (controller pass): Accessibility trust keys on the designated requirement, which for ad-hoc is the cdhash. Re-sign the Debug app with the Developer ID identity before permission-dependent tests.
- **KeyboardShortcuts names must not contain dots** (`1b11b99`) and `removeHandler(for:)` exists — don't work around a limitation the library doesn't have.

*Markdown preview (Plan 10):*
- **The HTML importer writes list markers twice** (`385579f`): literal "\t•\t" text *and* an `NSTextList`, which a TextKit 2 `NSTextView` draws again → double bullets. Clear `textLists` after import.
- **Setting `textColor` on an `NSTextView` rewrites the storage** (`385579f`): an `isEqual(to:)` guard against the storage never fires afterwards; compare against a last-applied copy held in the coordinator or every re-render drops selection and scroll.
- **The importer ignores `blockquote` margins** (`385579f`): no style boundary survives, so a post-pass cannot find the quote either. Accepted limitation.
- **A byte cap is not a cost cap** (PR #40 review): the importer's cost tracks list structure, not size, so `MarkdownPreview` caps `<li>` count as well as bytes. Anything main-actor and synchronous needs the cap on the work.
- **`#expect` on an optional-chained receiver can never fail** (PR #40 review): `#expect((f?.familyName ?? "").contains("Menlo"))` expands to a call check whose result is discarded (the compiler says "result of call to 'contains' is unused") and passes on any input. Bind to a local first — and treat that warning as a broken test, not noise.

*Secret detector (Plan 11) — two independent reviews measured the same regex disaster; a timing test only protects against the shapes it contains:*
- **A three-class bounded regex still backtracks catastrophically** (`85ced94`): `[A-Za-z0-9_-]{8,2048}\.[…]{8,4096}\.[…]{8,2048}` restarted a 2 KB scan at every hyphen — 10 s per 256 KB of base64url, 41 s per MB, on the main actor at every summon and capture. Tokenise linearly and validate; never regex a JWT.
- **A timing test with spaces in its input tests nothing** (`85ced94`): `"sk-abc "` repeated caps every run at 7 chars. Adversarial timing shapes must be single unbroken runs, BEGIN-without-END floods, and maximal-length prefixes.
- **A lazy `[\s\S]{0,N}?` window is O(n×N)** (`85ced94`): 3 s per MB of BEGIN markers with no END. Find both markers with bounded patterns and pair them.
- **Quoted keys** (`85ced94`): `\b(password|…)\b\s*[:=]` cannot see `"password": "…"`, which is how JSON/YAML/PHP write credentials. Allow an optional quote before and after the key and accept `=>`.
- **A redaction token must not re-trigger the detector** (`85ced94`): a bare `[REDACTED]` still matched the URL-password class, so the badge never cleared. Test detector quiescence (`scan(redact(x)).isEmpty`), not string idempotence.
- **Shannon entropy is length-biased** (`85ced94`, `98b6a84`): a fixed 3.5 bits/char fires on 11% of random 16-hex keys and on none of the placeholders you want quiet; normalise (by the alphabet — see the next entry, the length divisor was the round-2 mistake) and require a digit.
- **A candidate cap that stops the walk is a silent off-switch** (`98b6a84`): realistic identifier-heavy text exhausted the JWT budget and every later JWT was missed. Budgets bound work on weak candidates, never the scan.
- **The app target's deployment target was 14.6 while the project said 26.3** (`e06fb8e`): `TextSelection` failed to compile until the target-level override was found. Check `xcodebuild -showBuildSettings`, not the project pane.
- **Normalising entropy by length inverts the bar** (PR #42 review): `H / log2(len)` gets *harder* as the value gets longer, because `H` is capped by the alphabet while the divisor keeps growing — 64-hex keys scored 0/200 and a 256-bit key scanned clean, while the 16-character case it was introduced to fix still passed. Normalise by the observed alphabet (`log2(distinct)`), which is length-independent, and do the placeholder filtering with cheap explicit rules (a digit, a distinct-character floor) rather than by bending the entropy bar.
- **An unscanned buffer must not look clean** (PR #42 review): every consumer read `scan`'s empty result above the 256 KB cap as "no secrets" — no badge, `RedactSecrets` reporting `.unchanged`, `containsSecret = false` persisted — so a buffer 17 bytes over the cap with a live key at position 0 told the user nothing. A cap on a safety feature needs three things alongside it: a visible state (the grey "Not scanned for secrets" badge), a transform that throws instead of no-opping, and a tri-state flag (`Bool?`, nil = never examined) so "we didn't look" is never persisted as "we looked and it was fine".
- **`\b` succeeds mid-token whenever the token can contain `-`** (PR #42 review): a bounded `{10,200}` vendor rule ending in `\b` matched the first 202 characters of a 300-character `xoxb-` token, redaction left the tail behind and the rescan came back clean. End token rules in `(?![A-Za-z0-9_\-])` so an over-long token fails outright — a partial redaction of a secret is worse than no match.
- **A selection binding into an `ObservableObject` steals focus** (`e30f71d`): a `TextEditor` writes its selection back on every caret move and focus change, so an `@Published` selection republished the model, re-rendered the panel and re-applied the selection to the editor — ⌘K opened the palette and the editor immediately took first responder back, so typing went into the buffer. Editor selection belongs in the view's `@State`; the model may only *request* one, one-shot.

*Regex presets (Plan 12):*
- **`enumerateMatches` only calls its block on a match unless `.reportProgress` is set** — a deadline check without it never runs inside a backtracking attempt (10.9 s unthrown). The option is the only reason a user pattern's deadline is observable at all; never "simplify" it to `[]`.
- **A pre-sort before a final `(order, name)` sort is dead code** — sort once with the comparator you mean. Every preset shares order 900, so the case-insensitive pre-sort of `config.presets` was erased by the tuple sort's case-sensitive `String.<`, which put every capitalised name ahead of every lowercase one.
- **A Settings control that writes straight to the store publishes to the whole app** (this branch): `+` on the Presets tab called `addPreset`, so one click put a transform named "New preset" — with an uncompilable empty pattern, failing on every use — into the ⌘K palette, the sidebar and the Transforms tab. An editor over live, published state edits a draft and commits on Save; `+` makes the draft, nothing else.
- **Decoding a settings array with one `try?` turns a single malformed element into a wipe that the next mutation persists** (PR #44 review): `readJSON([RegexPreset].self, …) ?? []` meant one preset with a flag written as a string — or a missing `name`, or an id that isn't a UUID — decoded the *whole* list to `nil`, the store substituted `[]`, and the `didSet` on the next add/edit/delete wrote that empty array back over the user's presets. Decode arrays element-wise (`SettingsStore.readLossyArray`, per-element `try?` inside a wrapper whose `init(from:)` never throws, because a bare `try? container.decode` need not advance the unkeyed cursor), and test at the *array* level — a tolerant per-element `init(from:)` proves nothing about the array around it. Exception, by design: a list whose empty state is fail-open (`historyExcludedBundleIDs`) is better off falling back to its seeds than to the elements that happened to parse.
- **A discard alert only covers the exits it is wired to** (PR #44 review): the Presets editor confirmed before a selection change, a removal and **+**, and lost the draft silently to a tab switch or ⌘W — the two exits users actually take. Transient editor state that must outlive a `TabView` switch belongs in an `ObservableObject` owned by the parent (`PresetEditorState` on `SettingsView`), and the exit path with nowhere to put an alert (`onDisappear`) should commit what it legitimately can rather than discard it.

*Large-buffer safety (Plan 14):*
- **A `Sendable` struct that scans in `init` is only as cheap as its caller's actor**: `PasteDocument.init` ran `SecretDetector` + `ContentDetector` (~1.75 s per MB in `URLFinder`) on `AppModel`, so every summon, apply, undo and redo stalled the main thread (#28).
- **Check isolation before claiming a stall.** Issue #29 and the first draft of this spec said native transforms blocked the main actor; `TransformCoordinator.apply` is a nonisolated async function in the package, so synchronous bodies already ran on a pool thread. The real defect was that they were unbounded and uncancellable (the review caught the wrong comment).
- **A race that resumes the caller and leaves the work running** (`JSRunner`'s pattern) is not a bound; `Deadline.run` states the abandon semantics and always cancels the body so cooperative bodies stop.
- **Cancel that only discards the result:** `endSession` used the generation guard to drop a late result while the transform kept running; now every generation bump cancels the apply task and the detection lane.
- **Inserting requirements into a protocol shifts witness-table slots:** a stale incremental `.build` SIGSEGV'd in `TransformCoordinatorTests` after `maxInputBytes`/`timeout` were added before `apply`. Clean build; and the Xcode app needs a full rebuild too.
- **Fixed sleeps in concurrency tests flake under the default parallel runner:** a 1 s scan inside a 1.3 s `settle` failed under load. Poll a condition with a generous ceiling and assert it afterwards; `.serialized` on the suite is a secondary measure only.
- **Toolchain:** `Thread.sleep(forTimeInterval:)` is `noasync` in Swift 6 mode (wrap it in a synchronous helper when a test needs an uninterruptible body); a mutating call inside `#expect(...)` does not compile (bind the result to a `let` first).

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
| 2c — Auto-update | Sparkle, hardened runtime, release script | ✅ merged, [PR #5](https://github.com/bnaylor/pastefix/pull/5) (`0cc1082`) |
| 3 — Content transforms | URL cleanup, Markdown link, case conversion, detection | ✅ merged, [PR #6](https://github.com/bnaylor/pastefix/pull/6) (`113bf42`) |
| 4 — Action bar | ⌘K palette, sidebar, categories | ✅ merged, [PR #8](https://github.com/bnaylor/pastefix/pull/8) (`ff9c7b3`) |
| 5 — Quick actions | JSON, encoders, JWT, colours, swatch | ✅ merged, [PR #30](https://github.com/bnaylor/pastefix/pull/30) (`ba0a829`) |
| 6 — Clipboard history | `HistoryStore`, `PasteboardMonitor`, ⌘⇧V overlay, Settings | ✅ merged — PR #33 (`ba2793a`) — [spec](docs/specs/2026-09-21-pastefix-v2-clipboard-history.md), [plan](docs/plans/2026-09-21-pastefix-v2-clipboard-history.md) |
| 7 — Sensitive-app exclusion | AppExclusionFilter, FrontmostAppTracker, Privacy tab, menu-bar pause | ✅ merged — PR #34 (`b2b5166`) — [spec](docs/specs/2026-09-21-pastefix-v2-sensitive-app-exclusion.md), [plan](docs/plans/2026-09-21-pastefix-v2-sensitive-app-exclusion.md) |
| 8 — Markdown ↔ rich text | MarkdownHTML, MarkdownFromRich, OutputMode, Rich Text category | ✅ merged — PR #35 (`1d99648`) — [spec](docs/specs/2026-09-21-pastefix-v2-markdown-rich-text.md), [plan](docs/plans/2026-09-21-pastefix-v2-markdown-rich-text.md) |
| 9 — Pinned snippets | pin/unpin, Pinned section, ⇧↵ paste, per-snippet hotkeys, Snippets tab | ✅ merged — PR #38 (`08f72d6`) — [spec](docs/specs/2026-09-21-pastefix-v2-pinned-snippets.md), [plan](docs/plans/2026-09-21-pastefix-v2-pinned-snippets.md) |
| 10 — Markdown preview | MarkdownPreview, MarkdownPreviewView, ⌘⇧M toggle | ✅ merged — PR #40 (`c98cca8`) — [spec](docs/specs/2026-09-21-pastefix-v2-markdown-preview.md), [plan](docs/plans/2026-09-21-pastefix-v2-markdown-preview.md) |
| 11 — Secret detector | SecretDetector, Redact Secrets, secrets badge, history flag | ✅ merged — PR #42 (`85d7fd7`) — [spec](docs/specs/2026-09-21-pastefix-v2-secret-detector.md), [plan](docs/plans/2026-09-21-pastefix-v2-secret-detector.md) |
| 12 — Regex presets | RegexPreset, RegexPresetTransformer, Presets tab | ✅ merged — PR #44 (`955f01b`) — [spec](docs/specs/2026-09-21-pastefix-v2-regex-presets.md), [plan](docs/plans/2026-09-21-pastefix-v2-regex-presets.md) |
| 14 — Large-buffer safety | DetectionScheduler, Deadline.run, maxInputBytes/timeout, URLFinder cap | ✅ merged — PR #53 (`7bd250c`) — [spec](docs/specs/2026-09-23-pastefix-v2-large-buffer-safety.md), [plan](docs/plans/2026-09-23-pastefix-v2-large-buffer-safety.md) |

Historical reference material for the 2007 and 2019 incarnations is vendored under [`docs/inputs/legacy/`](docs/inputs/legacy/).

**Roadmap** — the remaining v2 goals are [GitHub issues](https://github.com/bnaylor/pastefix/issues) labelled `tier: first`, `tier: soon`, `tier: later` (the original tiers from the retired `docs/inputs/initial_requirements.md`). New feature work starts from an issue, gets a spec under `docs/specs/`, then a plan; the PR closes the issue.

- **Design specs:** `docs/specs/YYYY-MM-DD-feature-name.md`
- **Implementation plans:** `docs/plans/YYYY-MM-DD-feature-name.md`
- **Reviews:** `docs/reviews/YYYY-MM-DD-feature-name-review.md`
- These three dated directories are canonical. Do **not** save specs/plans/reviews under `superpowers/` or anywhere else.

## Git & house style

- **Conventional commits** (`feat(core):`, `fix(core):`, `docs:`, `refactor:` …). Commit at natural stopping points, not in one giant dump.
- **Co-credit the agent** in commit trailers (`Co-Authored-By: Claude …` / Gemini / etc.).
- **`main` is protected and merged branches auto-delete on GitHub.** Even doc-only changes go through a PR; don't try to push to `main` directly, and don't bother deleting remote branches after merge.
- **PR everything that maps to a feature or a bug fix.** Do the work on a branch, open a PR against `main`, and let review run. Commit directly to `main` only for genuinely trivial changes (doc typos, comments, `.gitignore`) or a real emergency — which, for a clipboard app, should be vanishingly rare. Keep `main` releasable.
- Comments explain non-obvious *why*, not *what*; match the surrounding file's density and idiom. No emoji in code or commit subjects. No orphan `TODO`/`FIXME` without a tracked issue.
- No premature abstraction — the codebase is still small.

## Where to look first

- New here? Read the spec end-to-end, then trace a transform: `TransformerRegistry.load()` → a `Transformer.apply(_:)` (native, then `ShellRunner.run` / `JSRunner.run`) → `TransformError` back out.
- `git log --oneline -- <path>` shows recent intent; commit messages are descriptive.
