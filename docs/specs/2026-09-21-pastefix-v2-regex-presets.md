---
type: spec
status: approved
id: 2026-09-21-pastefix-v2-regex-presets
title: Pastefix v2 — Regex Presets (Plan 12)
description: User-defined regex find & replace rules stored as settings data, each surfaced as a real transform (palette, sidebar, enable/reorder) in a "Presets" category; a Presets settings tab with a live preview; input cap and timeout so a bad pattern can't hang the panel.
tags: [pastefix, macos, swift, regex, transforms, settings]
timestamp: 2026-09-21T14:00:00Z
---

# Pastefix v2 — Regex Presets (Plan 12)

Source: [issue #12](https://github.com/bnaylor/pastefix/issues/12). Builds on Plan 1's registry
and overrides, Plan 4's palette/sidebar, and the bounded-regex lessons of Plans 8 and 11.

## Amendments (post-implementation)

The plan below was written before implementation; these are where the shipped code differs.

1. **`.reportProgress` is load-bearing for the deadline, not decorative.**
   `NSRegularExpression.enumerateMatches` only invokes its block when it finds a match, unless
   `.reportProgress` is passed, in which case it also invokes the block periodically *during* a
   single long match attempt. Without the option, a catastrophically backtracking pattern (e.g.
   `(a+)+$` against a non-matching run) spends its entire budget inside one `enumerateMatches`
   call with the block never invoked, so `RegexPresetTransformer.replace`'s
   `ContinuousClock`-deadline check is never reached — measured 10.9 s unthrown against the
   outer 3 s timeout race. `enumerateMatches(options: [.reportProgress], …)` must never be
   "simplified" to `[]`.
2. **`RegexPresetTransformer.preview(_:preset:deadline:)` is a public wrapper**, not part of the
   `apply`/`replace` pair the spec's Architecture section shows. It exists because the Settings
   preview needs both the replaced output and a match count, and `replace` — deliberately
   `internal`, since running a preset for real is `apply`'s job — isn't visible from the app
   target. It is a **single pass**: `replace` returns `(output, matches)`, since it counts the
   matches it substitutes anyway. The first implementation counted in a second `enumerateMatches`
   pass sharing one absolute deadline, which halved the budget per pass — a pattern the real
   transform ran in 0.7 s reported "took too long" in the editor and threw away an output pass 1
   had already computed correctly.
3. **An empty pattern does not compile.** `NSRegularExpression(pattern: "", options:)` throws
   (`Invalid pattern: The value "" is invalid.`), so the "does it compile" lint already refuses
   it and Save stays disabled — the editor just shows "Pattern is empty" rather than that
   message, because the field is untouched rather than mistyped. (An earlier version of this
   amendment claimed the opposite; measured, it throws.) That lint is not what keeps a bare
   preset out of the palette, though: **+** creates an *unsaved draft* and only Save writes to
   `SettingsStore`. Persisting on **+**, as the first implementation did, put a transform named
   "New preset" — one that failed on every use — into the palette, the sidebar and the
   Transforms tab the moment the button was pressed.
4. **The preview's match count stops at 1 when `replaceAll` is off.** Counting past the first
   match would report substitutions the transform never made, so the count the preview shows is
   the one `replace` accumulated before `stop.pointee = true` — the same early stop, by
   construction, now that amendment 2 made it one pass.
5. **The registry sorts the whole entry list once, with `localizedStandardCompare` on the name.**
   Presets all share `order == 900`, so a `($0.order, $0.name) < ($1.order, $1.name)` tuple sort
   ordered them by case-sensitive `String.<` — every capitalised name ahead of every lowercase
   one — and made the case-insensitive pre-sort of `config.presets` dead code. There is now one
   sort, comparing the order first and the name with `localizedStandardCompare`; the pre-sort is
   gone. This also fixes script names in the 1000 band.
6. **The Presets tab is a preset menu above a full-width editor**, not a side list beside it.
   The Settings window is fixed at 460 pt and the spec's two-column sketch left the pattern and
   replacement fields — the two things the tab exists to edit — about 100 pt of visible text
   inside a grouped `Form`. A `Picker` plus `+`/`−` across the top gives the editor the whole
   window. The editor also marks a dirty draft with a `•` (and a new one as *(unsaved)*) and
   confirms before a selection change or a removal discards unsaved edits.
7. **`RegexPreset` decodes tolerantly.** `SettingsStore` reads the array with `try?` and falls
   back to `[]`, so a synthesized (all-keys-required) `init(from:)` meant one element written by
   a build with a different field list — or one hand-edited preset — silently wiped *every*
   preset, permanently, on the next `didSet`. `init(from:)` is explicit: `id`, `name` and
   `pattern` are required; everything else is `decodeIfPresent` with the memberwise default.
8. **`expandEscapes` emits an ICU template, so backslashes are doubled.** Its output is handed
   to `NSRegularExpression.replacementString(for:in:offset:template:)`, which reads `$1` as a
   group reference and treats a backslash as an escape — i.e. it un-escapes the string a second
   time. The first implementation emitted backslashes raw, so a user could not produce a literal
   backslash at all (`\\` yielded the empty string) and every unrecognised escape lost its
   backslash (`\d` yielded `d`). The rule is now: `\n`/`\t` become real characters; `\\` and any
   other `\x` are emitted with a *doubled* backslash so one survives ICU; `\$` is passed through
   so ICU turns it into a literal dollar. The tests assert through `apply`, not on the
   intermediate template — the old test pinned `expandEscapes(#"\\n"#) == #"\n"#` while the user
   was actually getting `n`.
9. **Output is capped at 2 MB (`8 * maxBytes`), not just input and time.** A replacement is
   applied once per match, so output size is not bounded by input size: pattern `(?:)` with a
   4 KB replacement over a 256 KB input reached **1.2 GB peak RSS** inside the 3 s window before
   the deadline discarded all of it. `replace` now throws
   `invalidInput("Replacement output is too large (limit 2 MB)")` as soon as the accumulated
   output passes the cap. `preview` also applies the 256 KB *input* cap, which previously lived
   only in `apply` — `preview` is a second public door into `replace`.
10. **The timeout race is a second error path, not a bound.** `withThrowingTaskGroup` awaits its
   remaining children before propagating an error, so the sleeping task cannot cut a running
   synchronous `replace` loose: measured with a deadline-blind worker, the sleeper fired at
   3.189 s and the caller unblocked at 10.911 s. The in-block deadline check — reachable only
   because of `.reportProgress` (amendment 1) — is the entire protection; the race only ensures
   that a deadline noticed slightly late still surfaces as `.timeout` at exactly 3 s. Comments
   crediting the race with "a hard timeout race so the panel never hangs" were wrong and are
   gone: they told a future reader that deleting `.reportProgress` was safe.
11. **The editor's draft is owned by `SettingsView`, and a valid draft auto-saves on the way
   out.** As `@State` on the Presets tab the draft died with the view, and a `TabView` tears the
   tab down on every switch — so the discard alert (amendment 6) covered a selection change, a
   removal and **+**, but not the two exits a user actually takes: clicking another tab, and ⌘W.
   `PresetEditorState` (an `ObservableObject` holding `selected` and `draft`) is now a
   `@StateObject` on `SettingsView`, and `PresetsSettingsView.onDisappear` writes a dirty draft
   to the store if it is savable. The rule: **a valid unsaved draft is saved automatically when
   the tab or the window closes; an invalid one (no name, or a pattern that doesn't compile)
   survives tab switches but not window close** — it can't be written to the store, and the
   state object dies with the Settings window. No `NSWindow.willCloseNotification` observer: the
   notification is per-window and filtering it down to the Settings window from inside a SwiftUI
   tab costs more than it buys, and if `onDisappear` were ever *not* to fire on close, that same
   fact would mean the scene — and the draft — is still alive.
12. **Preset names are trimmed in `SettingsStore`, not in the editor.** Save validated
   `name.trimmingCharacters(...)` and then stored the untrimmed string, so `"  x  "` was savable
   and sorted ahead of every other name in the 900 band. `addPreset`/`updatePreset` trim
   (`.whitespacesAndNewlines`, the same set the editor validates with) so every writer —
   including the auto-save above — gets it.
13. **`removePreset(id:)` also drops the preset's `transformEnabled`/`transformOrder` entries.**
   They are keyed by `preset:<uuid>`, which no longer exists; left behind, restoring a presets
   backup brings back a stale "disabled" for a preset the user deleted.
14. **The presets array decodes element-wise.** Amendment 7's tolerant `init(from:)` only covered
   *missing optional* keys; the array itself was still one `try?`, so a single malformed element
   — a flag written as a string, a missing `name`, an `id` that isn't a UUID — decoded to `nil`,
   became `[]`, and the next add/edit/delete wrote that empty array back over the file. Measured
   against the real decoder: one good preset plus any one of those three lost *both*.
   `SettingsStore.readLossyArray` decodes each element through a wrapper whose `init(from:)`
   never throws (a bare `try? container.decode` is not guaranteed to advance the unkeyed
   container's cursor), keeping the good ones. `historyExcludedBundleIDs` deliberately keeps the
   whole-array decode: an all-bad `[String]` payload would decode element-wise to an *empty*
   exclusion list, which is fail-open for a privacy feature, where falling back to the seeds is
   fail-safe.

## Scope

**In scope:**

- `RegexPreset` (Codable, Sendable): `id`, `name`, `pattern`, `replacement`, `caseInsensitive`,
  `anchorsMatchLines`, `dotMatchesNewlines`, `replaceAll`. Persisted in `SettingsStore.regexPresets`
  (JSON via the existing helpers). `add/update/remove` mutators.
- `RegexPresetTransformer` (PastefixCore): id `preset:<uuid>`, `source: .preset(id)`,
  `category: TransformCategory.presets` ("Presets"), no `applicableKinds`; compiles the pattern
  once; input cap 256 KB (`invalidInput`); runs the replace off the main actor under a 3 s
  timeout (`TransformError.timeout`); match enumeration stops when the deadline passes;
  replacement template is `NSRegularExpression` syntax (`$1`, `\$`) with `\n`, `\t`, `\\`
  escapes expanded first; `replaceAll` false → first match only.
- Registry: `RegistryConfig.presets: [RegexPreset]`; presets emitted at order 900 (between
  built-ins ≤ 110 and scripts 1000), sorted by name within the band; `TransformCategory.presets`
  appended to `builtinOrder` after Privacy so the sidebar places it before Scripts.
- App: `AppModel.reload()` passes `settings.regexPresets`; a settings sink reloads on change.
- Settings → **Presets** tab: list (name; + / −), editor (name, pattern, replacement, four
  toggles), sample-input box with live preview (result + match count, debounced 200 ms,
  capped at 16 KB, 1 s timeout) and an inline error for a pattern that doesn't compile; Save
  disabled while the pattern is invalid or the name is empty. Presets appear in the Transforms
  tab automatically.
- README, AGENTS (layout; Invariant 8 gains the 900 band; Patterns: presets run under the
  script timeout and the input cap), spec.

**Out of scope:** import/export; per-preset `applicableKinds`/detection; preset hotkeys;
sharing presets as scripts; multi-step pipelines; a regex lint beyond "does it compile".

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Storage | Settings JSON, not generated scripts | Pure data; no files, shells or metadata headers to keep in sync. |
| Identity | `preset:<uuid>`; `TransformerSource.preset(UUID)` | Stable ids keep enable/reorder overrides valid across renames. |
| Order | Fixed band 900, name-sorted; user reorder via existing overrides | Between built-ins and scripts; Invariant 8 amended. |
| Category | `TransformCategory.presets` = "Presets", last in `builtinOrder` | Fixed placement before Scripts instead of the alphabetical custom bucket. |
| Safety | 256 KB input cap; detached execution with a 3 s race; `enumerateMatches` `stop` on deadline; compile at edit time | A catastrophic user pattern must fail loudly, not freeze the panel (Plans 8/11). The orphaned matcher thread finishing late is accepted and documented. |
| Replacement escapes | Expand `\n`, `\t` to real characters and re-escape the rest for ICU before handing the template to `NSRegularExpression` | Single-line text fields can't type newlines. The result is a *template*, which ICU un-escapes a second time, so `\\` must be emitted doubled to yield one backslash, `\$` is kept so ICU makes a literal dollar, and any other `\x` is doubled so the escape survives verbatim (see amendment 8). |
| Preview | Sample box, 200 ms debounce, 16 KB cap, 1 s timeout, shows "n matches" or the error | Authoring is where a slow or wrong pattern should be caught. |
| Flags | Four toggles mapping to `.caseInsensitive`, `.anchorsMatchLines`, `.dotMatchesLineSeparators`, and replace-all vs first | The four that matter for find & replace; everything else stays default. |

## Architecture

### PastefixCore

```swift
public struct RegexPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    public var caseInsensitive: Bool
    public var anchorsMatchLines: Bool
    public var dotMatchesNewlines: Bool
    public var replaceAll: Bool
    public init(id: UUID = UUID(), name: String, pattern: String, replacement: String = "",
                caseInsensitive: Bool = false, anchorsMatchLines: Bool = true,
                dotMatchesNewlines: Bool = false, replaceAll: Bool = true)
    public var regexOptions: NSRegularExpression.Options
    public static func expandEscapes(_ template: String) -> String
    public func compile() throws -> NSRegularExpression        // throws TransformError.invalidInput("Invalid pattern: …")
}

public enum TransformerSource { … case preset(UUID) }
public enum TransformCategory { … static let presets = "Presets"; builtinOrder += [presets] }

public struct RegexPresetTransformer: Transformer {
    public static let maxBytes = 262_144
    public static let timeout: TimeInterval = 3
    public let preset: RegexPreset
    public init(preset: RegexPreset)
    // id "preset:\(preset.id.uuidString)", name = preset.name, category presets, source .preset(id)
    public func apply(_ input: TransformInput) async throws -> String
    /// Pure, synchronous core (testable without the timeout): throws invalidInput/timeout.
    static func replace(_ text: String, preset: RegexPreset, deadline: ContinuousClock.Instant?) throws -> String
}
```
`apply` checks the cap, then races `Task.detached { replace(…, deadline:) }` against a 3 s
sleep; the loser is cancelled (the detached matcher observes the deadline between matches).

`RegistryConfig` gains `presets: [RegexPreset] = []`; `load()` appends
`RegexPresetTransformer` entries with `order: 900` sorted by name before scripts.

### PastefixAppCore

`SettingsStore.regexPresets: [RegexPreset]` (`pastefix.regexPresets`, JSON; default `[]`),
`addPreset(_:)`, `updatePreset(_:)`, `removePreset(id:)`.

### Pastefix app

- `AppModel.reload()` → `RegistryConfig(…, presets: settings.regexPresets)`; delegate sink on
  `$regexPresets` → `model.reload()` (debounced 200 ms).
- `SettingsView` → `presets` tab (`text.badge.plus`): `NavigationSplitView`-free two-column
  `HStack`: left `List(selection:)` of presets + `+`/`−`; right `PresetEditor` bound to a draft
  copy with Save/Revert, the four toggles, a `TextEditor` sample box and a read-only preview
  (`RegexPresetTransformer.replace` with a 1 s deadline on a 16 KB cap, run in a `Task`,
  debounced 200 ms), error text in red under the pattern field.

## Data flow

Settings → Presets → + → name "Strip trailing spaces", pattern `[ \t]+$`, replacement empty,
anchors on → preview shows result → Save → ⌘⇧C → ⌘K "strip" → applied. Transforms tab lists it
under Presets for enable/reorder; the sidebar shows a Presets group before Scripts.

## Error handling

- Invalid pattern: editor shows the error and disables Save; a persisted-but-invalid preset
  (edited by hand) throws `invalidInput` at apply time → the existing error bar.
- Over cap → `invalidInput("Text is too large for a regex preset (limit 256 KB)")`.
- Timeout → `TransformError.timeout` (existing message); the orphan finishes in the background.

## Testing

`Tests/PastefixCoreTests/RegexPresetTests`: template groups `$1`; escapes `\n`/`\t`/`\\`/`\$`/`\d`, asserted end to end through `apply` because the intermediate template is not what the user sees; each
flag (case, anchors, dot-all); first vs all; invalid pattern throws `invalidInput`; over-cap
throws; deadline honoured on a pathological pattern (`(a+)+$` on `"a"*40 + "!"` with a 50 ms
deadline throws `timeout`, and the async `apply` also times out — mark that test's bound
generously); ids/category/source; `expandEscapes`.
`TransformerRegistryTests`: presets land at 900 between 110 and 1000, name-sorted; overrides
still apply by id; `builtinOrder` ends with Presets.
`SettingsStoreTests`: presets round trip; add/update/remove.
GUI pass (ask first): create a preset in Settings (preview shows matches), apply via ⌘K,
sidebar shows the Presets group; an invalid pattern disables Save.

## Documentation

- README: "Regex presets" section (what, where, template syntax, flags, limits).
- AGENTS.md: layout (`Native/RegexPresetTransformer.swift`, `RegexPreset.swift`,
  `PresetsSettingsView` if split out); Invariant 8 orders gain `900 (presets)`; Patterns: "user
  regexes run under the 3 s timeout with a 256 KB cap — never inline on the main actor";
  status row.

## Project layout delta

```
Sources/PastefixCore/RegexPreset.swift                    # model, escapes, compile
Sources/PastefixCore/Native/RegexPresetTransformer.swift  # transformer + timed replace
Sources/PastefixCore/Transformer.swift                    # .preset source; presets category
Sources/PastefixCore/Discovery/TransformerRegistry.swift  # presets at 900
Sources/PastefixAppCore/SettingsStore.swift               # regexPresets + mutators
Pastefix/Pastefix/AppModel.swift                          # pass presets to the registry
Pastefix/Pastefix/PastefixApp.swift                       # reload sink
Pastefix/Pastefix/SettingsView.swift                      # Presets tab (or PresetsSettingsView.swift)
```
