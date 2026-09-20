---
type: spec
status: approved
id: 2026-09-20-pastefix-v2-action-bar
title: Pastefix v2 — Action Bar Revamp: ⌘K Palette + Sidebar (Plan 4)
description: Replace the horizontally scrolling transform palette with a keyboard-first ⌘K command palette and an optional, persisted, category-grouped sidebar. Adds a `category` on transforms.
tags: [pastefix, macos, swiftui, ux, command-palette]
timestamp: 2026-09-20T23:30:00Z
---

# Pastefix v2 — Action Bar Revamp: ⌘K Palette + Sidebar (Plan 4)

Source: [issue #7](https://github.com/bnaylor/pastefix/issues/7) and its three
mockups (compact window with a "Transform… ⌘K" bar; the ⌘K palette with a
typed query and highlighted matches; the window with the sidebar shown, grouped
under LAYOUT / CHARACTERS / URLS).

## Scope

**In scope:**

- Remove the horizontal palette from `PanelView`.
- A bottom **action bar**: a search-field-styled button ("Transform…", ⌘K
  hint) plus the existing "Detected: …" badge and progress spinner.
- A **⌘K command palette** overlay: focused search field, ranked and
  highlighted results with category subtitles, ↑↓/↵/Esc keyboard model,
  click-outside to close.
- An optional **sidebar**: a 220-pt column listing enabled transforms grouped
  by category; toggled from the toolbar and ⌘⇧L; state persisted in
  `SettingsStore.showSidebar` (default off).
- `Transformer.category: String?` (default nil) with fixed categories for the
  built-ins and a `category` magic-comment key for scripts (default "Scripts").
- Pure, tested `TransformSearch` and `SidebarGrouping` in `PastefixAppCore`.
- README / AGENTS.md currency.

**Explicitly out of scope:**

- Any new transform. The mockups' "Trim Lines", "Sort Lines", "Remove
  Duplicate Lines", "Straighten Quotes", "Strip Formatting", "URL Decode" are
  placeholder content.
- Changes to the Settings window. The Transforms tab keeps enable/reorder.
- Per-transform keyboard shortcuts, recents/frequency ranking, pinned
  favourites. Natural follow-ups once the palette exists.
- Changing the panel's summon/save/cancel model, auto-hide, or the editor.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Palette host | SwiftUI overlay inside the existing `NSPanel` (ZStack over the editor) | The panel is `.nonactivatingPanel` + `.floating`; sheets/popovers over it fight for key status. An overlay needs no new AppKit glue and matches the mockup. |
| Sidebar host | Conditional column in an `HStack` | `NavigationSplitView` is too heavy for a floating utility panel and brings toolbar/sidebar chrome we don't want. |
| Grouping source | `Transformer.category: String?`; built-ins fixed; scripts via header, default "Scripts" | Mirrors how `applicableKinds` was added in Plan 3: additive, scripts can participate, no separate table to maintain. Free-form string so scripts can invent groups. |
| Category display order | Layout, Characters, URLs, Case, then custom categories alphabetically, then Scripts | Stable, predictable; built-ins first because they are the ones everyone has. |
| Sidebar persistence | `SettingsStore.showSidebar`, default `false` | User's call in the issue: persist, default closed. Same store and pattern as every other setting. |
| Search model | Pure `TransformSearch.rank(query:in:kinds:)` returning `[SearchResult]` with matched ranges | Testable without SwiftUI; the palette just renders results. |
| Ranking | Tier 1 name prefix; tier 2 any word start; tier 3 subsequence; within a tier: applicable-to-detected first, then user order. Case- and diacritic-insensitive. | Spotlight/Alfred expectations; Plan 3's detection keeps paying off inside the palette. |
| Empty query | All enabled transforms in `PaletteOrdering` order (applicable first) | ⌘K then ↵ applies the most relevant transform with zero typing. |
| Esc semantics | Esc closes the palette when open; otherwise Cancel (unchanged) | Two meanings, resolved by whichever surface is open. Cancel's `.cancelAction` binding is detached while the palette is open so one Esc can't dismiss the panel. |
| Sidebar shortcut | ⌘⇧L | Free in the panel; ⌘L alone is too close to "location" muscle memory. |
| Applying while applying | ⌘K and sidebar clicks disabled while `isApplying` | Same gate as before (Critical Invariant 10). |

## Architecture

### `PastefixCore`

**`Transformer.swift`**

```swift
public protocol Transformer: Identifiable, Sendable {
    …
    /// Display group for browsing UIs. `nil` = uncategorised (shown under "Scripts"
    /// for scripts; built-ins always set one).
    var category: String? { get }
}
public extension Transformer { var category: String? { nil } }
```

Built-ins set `public let category: String? = "Layout"` etc.:

| Transform | Category |
|---|---|
| Wrap & Reflow, Whitespace Cleanup | Layout |
| Rich → Plain Text, Transliterate to ASCII | Characters |
| Clean URL Tracking, URL → Markdown Link | URLs |
| camelCase, snake_case, kebab-case, CONSTANT_CASE | Case |

**`Scripting/ScriptMetadata.swift`** — new key `category` (free text, trimmed;
empty → nil). `ShellTransformer` / `JSTransformer` expose `metadata.category`.

```sh
# pastefix: name = Rot13
# pastefix: category = Text
```

Public constants for the built-in names live in one place so tests and the
grouping code share them: `public enum TransformCategory { public static let
layout = "Layout", characters = "Characters", urls = "URLs", `case` = "Case",
scripts = "Scripts"; public static let builtinOrder: [String] }`.

### `PastefixAppCore`

**`TransformSearch.swift`** (new)

```swift
public struct SearchResult: Identifiable, Sendable {
    public let transformer: any Transformer
    public var id: String { transformer.id }
    /// Ranges in `transformer.name` to highlight (empty for an empty query).
    public let matchedRanges: [Range<String.Index>]
    public let tier: Int     // 1 prefix, 2 word-start, 3 subsequence, 0 = no query
}

public enum TransformSearch {
    public static func rank(query: String,
                            in transformers: [any Transformer],
                            kinds: Set<ContentKind>) -> [SearchResult]
}
```

- Normalisation: both query and name are folded with
  `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`;
  matching is done on the folded strings and ranges mapped back to the
  original name via `Range(nsRange, in:)` over the folded/original pair
  (folding does not change grapheme count for the names we ship; the
  implementation must tolerate a mismatch by falling back to no highlight,
  never by crashing).
- Empty or whitespace-only query → `PaletteOrdering.order(transformers, for:
  kinds)` wrapped as results with `tier = 0`, no ranges.
- Non-empty query: tier 1 if folded name has the query as a prefix; tier 2 if
  any word (split on whitespace, `_`, `-`, `→`, `&`) starts with it; tier 3 if
  the query's characters appear in order (subsequence); otherwise excluded.
  Highlight: tiers 1–2 highlight the contiguous match; tier 3 highlights each
  matched character.
- Order: by tier, then applicable-first (`applicableKinds` intersects `kinds`),
  then the incoming (user) order. Stable.

**`SidebarGrouping.swift`** (new)

```swift
public struct SidebarSection: Identifiable, Sendable {
    public let title: String
    public var id: String { title }
    public let transformers: [any Transformer]
}
public enum SidebarGrouping {
    public static func sections(_ transformers: [any Transformer]) -> [SidebarSection]
}
```

Groups by `category ?? TransformCategory.scripts`; section order per the
Decisions table; within a section, incoming (user) order. Empty sections are
omitted.

**`SettingsStore`** — `@Published public var showSidebar: Bool` persisted
under `pastefix.showSidebar`, default `false`.

### `Pastefix` app

**`PanelView.swift`** — restructured:

```
VStack
  toolbar                       Undo Redo Refresh … [sidebar toggle] Cancel Save
  Divider
  HStack(spacing: 0)
    ZStack                       editor (+ error banner) with the ⌘K overlay on top
    if settings.showSidebar { Divider; SidebarView(width: 220) }
  Divider
  actionBar                     [🔍 Transform…            ⌘K]  Detected: URL  ⟳
```

- **Action bar:** a `Button` styled to look like a search field (rounded
  rect, magnifying glass, secondary "Transform…" label, trailing "⌘K" caption).
  Tapping it opens the palette. `.keyboardShortcut("k", modifiers: .command)`
  on this button provides ⌘K. Disabled while `isApplying`. The "Detected: …"
  badge and the `ProgressView` move here, trailing.
- **Sidebar toggle:** toolbar button with `sidebar.right` symbol, tooltip
  "Show/Hide Transforms Sidebar", `.keyboardShortcut("l", modifiers:
  [.command, .shift])`, bound to `settings.showSidebar`. The panel's minimum
  width grows by 220 while the sidebar is shown (`.frame(minWidth:)` computed).
- **`SidebarView`** (new file): `List` with `Section(header:)` per
  `SidebarSection`, plain rows showing the name; row tap → `model.apply`.
  Disabled while `isApplying`. Uses `.listStyle(.sidebar)`.
- **`CommandPaletteView`** (new file): shown as an overlay when
  `isPaletteOpen`. Dimmed backdrop (`Color.black.opacity(0.25)`, tap closes).
  Card ~520 pt wide, top-aligned with 40 pt inset. Contents: `TextField`
  (`@FocusState` set true on appear), results `List` (max 8 visible rows,
  scrolls), each row: highlighted name (`AttributedString` built from
  `matchedRanges`, bold + accent) and category subtitle in secondary caption;
  selected row highlighted with the accent tint; a ↵ glyph on the selected
  row. Footer: "↵ Apply   ↑↓ Choose   esc Close". Keyboard: `.onKeyPress(.upArrow /
  .downArrow)` move selection with wraparound; `.onSubmit` of the field or
  `.onKeyPress(.return)` applies the selected result (default: first);
  `.onKeyPress(.escape)` closes. Query and selection reset each open. Results
  come from `TransformSearch.rank(query:in:kinds:)` over
  `model.enabledTransformers()` (already applicable-first) and
  `model.document?.detectedKinds ?? []`.
- **Esc arbitration:** the Cancel button gets `.keyboardShortcut(.cancelAction)`
  only when `!isPaletteOpen` (conditional modifier via a small
  `ViewModifier`). While the palette is open, Esc reaches the palette's
  `onKeyPress` handler.
- **Apply from palette or sidebar:** `isPaletteOpen = false` then
  `model.apply(t)`. Focus returns to the editor after close
  (`@FocusState` on the editor set true).
- `isPaletteOpen` is `@State` in `PanelView` (session-local; always closed on
  summon — `PanelView` resets it in `onChange(of: model.document == nil)`).

**`AppModel`** — no new state. `enabledTransformers()` already provides the
ordered list.

### Focus and key handling notes

The panel is key while shown (the editor already receives typing), so
`@FocusState` works. `onKeyPress` requires macOS 14, which the target already
sets as its floor. Arrow keys in a `TextField` would otherwise move the caret;
the handlers return `.handled` for ↑/↓ so the caret stays put. ⌘K while the
palette is open closes it (toggle).

## Data flow

Summon → panel shows compact (or with sidebar if persisted) → user presses ⌘K
→ overlay opens with empty query → results = `enabledTransformers()` in
applicable-first order → user types "url" → `TransformSearch.rank` re-ranks on
each keystroke (list of ≤ ~30 items; trivial) → ↵ → palette closes →
`model.apply(selected)` → existing apply path (gate, spinner in the action bar,
document push) → editor updates. Sidebar click follows the same path from a
row tap. Toggling the sidebar writes `settings.showSidebar`, which the
`PanelView` observes and animates.

## Error handling

Nothing new can fail. An empty result set shows "No matching transforms" in the
list area; ↵ does nothing. If `matchedRanges` cannot be mapped back onto the
original name, the row renders without highlight. Applying goes through the
unchanged `TransformCoordinator` path with its existing error banner.

## Testing

`Tests/PastefixAppCoreTests/`:

- `TransformSearchTests`: empty query → `PaletteOrdering` order, tier 0, no
  ranges; prefix beats word-start beats subsequence (`"url"` vs "Clean URL
  Tracking" (word-start), "URL → Markdown Link" (prefix)); case-insensitive
  (`"CLEAN"`); diacritic-insensitive (a fake "Café" transform matched by
  `"cafe"`); subsequence (`"cut"` matches "Clean URL Tracking"; ranges are the
  three characters); non-match excluded; applicable-first within a tier
  (two prefix matches, one with `kinds [.url]`, detected `[.url]`); stability
  (equal tier, equal applicability → input order); highlight ranges are valid
  indices of the original name; whitespace-only query treated as empty.
- `SidebarGroupingTests`: built-in order Layout, Characters, URLs, Case;
  custom categories alphabetical after; nil → Scripts last; empty sections
  omitted; within-section order preserved.
- `SettingsStoreTests` addition: `showSidebar` default false, round-trips.

`Tests/PastefixCoreTests/`:

- `ScriptMetadataTests` addition: `category = Text`, `category =` (empty →
  nil), absent → nil, trimmed.
- `TransformerRegistryTests` addition: every built-in has a non-nil category
  matching the table; a script with a `category` header surfaces it; one
  without → nil.
- Each native transform's `metadata()` test gains a `category` assertion.

Manual (app): ⌘K opens with the field focused; typing filters live with
highlights; ↑↓ move with wraparound; ↵ applies and closes; Esc closes only the
palette; a second Esc cancels the panel; clicking the backdrop closes; ⌘K
while applying does nothing; the sidebar toggle and ⌘⇧L show/hide the column,
the window widens, the state survives relaunch; sidebar rows apply; the
Detected badge and spinner sit in the action bar; Settings → Transforms
disable/reorder is reflected in both surfaces; the old horizontal bar is gone.

## Documentation

- `README.md`: replace the palette description under "The app" with
  "Finding transforms" (⌘K palette, ranking, sidebar + ⌘⇧L, persisted);
  add `category` to "Script Metadata" with the built-in category table.
- `AGENTS.md`: layout entries (`TransformSearch.swift`, `SidebarGrouping.swift`,
  `SidebarView.swift`, `CommandPaletteView.swift`); note under "Patterns":
  *browsing UIs read `enabledTransformers()`; ordering/grouping/searching are
  pure functions in AppCore*; a "bitten us" entry only if something bites;
  status table row for Plan 4.

## Project layout delta

```
Sources/PastefixCore/
  Transformer.swift               # + category (default nil), TransformCategory constants
  Scripting/ScriptMetadata.swift  # + category key
  Native/*.swift                  # + category on each built-in
Sources/PastefixAppCore/
  TransformSearch.swift           # rank(query:in:kinds:) -> [SearchResult]
  SidebarGrouping.swift           # sections(_:) -> [SidebarSection]
  SettingsStore.swift             # + showSidebar
Pastefix/Pastefix/
  PanelView.swift                 # action bar, sidebar column, overlay host, Esc arbitration
  SidebarView.swift               # grouped List
  CommandPaletteView.swift        # ⌘K overlay
```

## Open questions / future increments

- Recents / frequency-weighted ranking once usage data exists.
- Per-transform user-assigned shortcuts (the palette makes them discoverable).
- Pinned favourites section at the top of the sidebar.
