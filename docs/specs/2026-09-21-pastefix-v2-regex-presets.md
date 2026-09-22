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
| Replacement escapes | Expand `\n`, `\t`, `\\` before handing the template to `NSRegularExpression` | Single-line text fields can't type newlines; `\\` lets a literal backslash through. |
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

`Tests/PastefixCoreTests/RegexPresetTests`: template groups `$1`; escapes `\n`/`\t`/`\\`; each
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
