---
type: spec
status: approved
id: 2026-09-21-pastefix-v2-pinned-snippets
title: Pastefix v2 — Pinned Snippets & Hotkey Paste (Plan 9)
description: Pin history items or the editor buffer as snippets that never evict; a Pinned section in the ⌘⇧V overlay; ⇧↵ pastes any row into the app you came from; per-snippet global hotkeys that paste into the frontmost app (Accessibility-gated, copy-only fallback); a Snippets settings tab.
tags: [pastefix, macos, swift, clipboard, history, snippets, hotkeys]
timestamp: 2026-09-21T08:00:00Z
---

# Pastefix v2 — Pinned Snippets & Hotkey Paste (Plan 9)

Source: [issue #17](https://github.com/bnaylor/pastefix/issues/17). Builds on Plan 6
(history store + overlay), Plan 7 (`FrontmostAppTracker`), and Plan 8 (rich items).

## Amendments (post-implementation)

The plan below was written before implementation; these are where the shipped code differs.

1. **Shortcut names use a hyphen, not a dot.** `KeyboardShortcuts` rejects names containing
   `.` (`isValidShortcutName`), so the per-pin name is `snippet-<uuid>`, not `snippet.<uuid>`.
   Unpinning is reversible: it removes the handler but keeps the recorded shortcut and the
   title, so ⌘P twice is a no-op and a re-pin of the same item gets its shortcut back. A
   shortcut is `reset` only when the item leaves the store entirely (evicted, removed,
   cleared); a sweep at every sync also resets combos whose item no longer exists — except
   after a quarantined index load, when the store cannot see its items. `SnippetRow`'s
   `KeyboardShortcuts.Recorder` uses `.shortcutValidation` to refuse a combo already bound to
   another pinned snippet or to the summon shortcuts; the Shortcut tab validates the other way.
2. **`unpin` gives the item a fresh `capturedAt` and reinserts it at the top of `items`**,
   rather than restoring its original capture position, and then re-applies `enforceLimits()`.
   Unpinning a long-lived pin therefore always rejoins history as the newest item — it is never
   immediately evicted by the cap it had been exempt from.
3. **`clear()` and `clearAll()` are two separate methods, not one dialog-parameterized call.**
   `clear()` removes unpinned items only (pins and their blobs survive); `clearAll()` removes
   everything, including pins. The Privacy tab's confirmation offers both as separate buttons:
   "Clear N items" (unpinned count) and "Clear Everything (N)" (total count).
4. **Paste mechanics are more involved than "wait ~150ms, post ⌘V":** `SnippetPaster.paste`
   writes the clipboard and requests activation synchronously, then polls every 20ms (up to a
   1s deadline) for two conditions to hold together — no blocking modifier
   (shift/control/option/command) is physically down, and the target process is really
   frontmost (asked of Accessibility's focused-application attribute, which answers synchronously, with `NSWorkspace` as fallback; this narrows the check-to-post window, it cannot close it) — and no Pastefix window is key — before posting ⌘V exactly once. Caps Lock is deliberately excluded from the
   watched modifiers (it latches and would never clear). A timeout posts nothing; the clipboard
   already has the snippet. The event is built from a `.privateState` `CGEventSource` (not
   `.combinedSessionState`, which would merge in live hardware modifiers) carrying only
   `.maskCommand`. A newer `paste` call bumps a generation counter that supersedes any older
   pending post. The target is refused (copy-only, nothing posted) when it is `nil`,
   terminated, Pastefix itself, or its activation request is refused. Both the hotkey path and the overlay's ⇧↵ beep when a paste gives up or is refused. Any
   clipboard write from the app (Save, copy-back, palette) supersedes a pending paste. If the
   layout's key code for "v" cannot be resolved, nothing is posted (never a cached guess).
5. **`pasteIntoPreviousApp` posts the paste (and activates the target) *before* calling
   `endSession()` to hide the panel** — not after. Activation has to be requested while Pastefix
   is still the active app so it can hand off cooperatively; requesting it after hiding asks for
   an activation Pastefix no longer owns, which macOS is more likely to refuse or reorder. "The
   previous app" is `FrontmostAppTracker.previousApp` — the most recent non-Pastefix app the
   tracker saw activated — injected into `AppModel` via `previousAppProvider`.
6. **⌘P in the overlay re-points the highlight at the toggled item after re-ranking.** Pinning
   or unpinning re-sorts `results` (pins move to/from the Pinned section), so `togglePinSelected`
   looks up the toggled item's new index and moves `selection` there — otherwise a second ⌘P
   (the natural "undo that") would land on a different row.

## Scope

**In scope:**

- **Model:** `HistoryItem.pinned: Bool` (default false) and `title: String?`. Pinned items
  are exempt from the item cap and byte eviction; `clear()` keeps them; a copy that
  matches a pinned item is a no-op. `HistoryStore.pin/unpin/rename/pinText`. Backward-
  compatible decoding of indexes written before this plan.
- **Search:** pins rank with a haystack of `title + text`; on the empty query and on tier
  ties pins come first.
- **Overlay:** a "Pinned" section above "History" when the query is empty; pin glyph and
  bold title on pinned rows; **⌘P** toggles pin on the highlighted row (untitled);
  **⇧↵** pastes the highlighted row into the app that was frontmost before Pastefix.
- **Editor:** toolbar pin button, **⌘⇧P**, pins the current buffer (with the origin's
  rich data) via a popover that takes an optional title.
- **Hotkeys:** per-pin global shortcut recorded in Settings → Snippets; firing it writes
  the snippet to the clipboard and sends ⌘V to the frontmost app.
- **`SnippetPaster`:** Accessibility trust check; paste when trusted, copy-only plus the
  system permission prompt (once per launch) when not.
- **Settings → Snippets tab:** list of pins with inline title, shortcut recorder,
  Unpin; an Accessibility status line with "Open System Settings".
- README, AGENTS (layout; note: Accessibility is requested only to *send* ⌘V, never to
  observe keystrokes), spec.

**Out of scope:** typed-abbreviation expansion (event tap); image pins; snippet
placeholders/variables; syncing; reordering pins by drag (they list newest-pinned first);
pinning from the ⌘K palette (transforms only).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Pins are history items | A `pinned` flag on `HistoryItem`, same index and blobs | One store, one overlay, one search; pinning a history row is a flag flip, not a copy. |
| Eviction | Cap and byte budget count and evict *unpinned* items only; a document of pins can exceed `maxItems` | Pins are the user's explicit keepers. |
| Clear History | Removes unpinned items only; dialog text says pins are kept | The Privacy-tab button is about forgetting captures, not curated snippets. |
| De-dup vs pins | Copying text equal to a pin returns the pin, unmoved, records nothing | Hotkey paste writes the pin to the clipboard; the monitor must not create churn. |
| Pin ordering | `pinnedAt` timestamp on the item; Pinned section newest-pinned first | Stable, no drag-reorder needed yet. |
| ⌘P in the overlay | Toggles pin on the highlighted row, untitled; titles are set from the editor popover or Settings | Keeps the overlay keyboard-only; a title prompt there would steal focus from search. |
| ⇧↵ | Copy the row to the clipboard, hide the panel, activate the previous app, send ⌘V; falls back to copy + hide when not trusted | The CopyClip loop in one keystroke; applies to every row, not only pins. |
| Previous app | `FrontmostAppTracker.previousApp` — the most recent non-Pastefix `NSRunningApplication` it saw | Already tracking activations for Plan 7. |
| Sending ⌘V | `CGEvent` key down/up for virtual key 9 with `.maskCommand` from a `.privateState` source, posted to `.cghidEventTap` only once shift/control/option/command are all up and the target is verified frontmost (polled every 20 ms, 1 s deadline; timeout posts nothing) | The standard approach; needs Accessibility (`AXIsProcessTrusted`). Waiting on modifiers and frontmost avoids posting a chord (e.g. ⌥⌘V) or into the wrong app — see Amendment 4. |
| Permission UX | `SnippetPaster.ensureTrusted()` calls `AXIsProcessTrustedWithOptions` with the prompt option at most once per launch; the Snippets tab shows "Paste with hotkey: ready / needs Accessibility" and an "Open System Settings" button | The system prompt is the canonical UI; we only add status and a shortcut to the pane. |
| Hotkey identity | `KeyboardShortcuts.Name("snippet-<uuid>")` (hyphen — the library rejects a dot); unpin resets the recorded shortcut, then removes the handler | The library persists bindings by name in UserDefaults; deriving from the id makes cleanup exact. See Amendment 1. |
| Hotkey action | Write clipboard (text + RTFD when present) → paste into `NSWorkspace.frontmostApplication` (no activation needed) | The user is already where they want the text. |
| Unpin in Settings | "Unpin" (item returns to normal history, subject to eviction), not delete | Least destructive; ⌘⌫ in the overlay still deletes. |

## Architecture

### PastefixAppCore

```swift
public struct HistoryItem { … public var pinned: Bool = false; public var pinnedAt: Date?; public var title: String? … }
// custom init(from:) with decodeIfPresent so pre-Plan-9 indexes load (pinned = false).

extension HistoryStore {
    public var pinnedItems: [HistoryItem]      // pinned, newest pinnedAt first
    public var unpinnedItems: [HistoryItem]    // in existing (newest capture first) order
    public func pin(_ id: UUID, title: String? = nil)     // sets pinned, pinnedAt = now; flush
    public func unpin(_ id: UUID)                          // clears pinned/pinnedAt/title; then enforceLimits; flush
    public func rename(_ id: UUID, title: String?)         // trims; empty → nil; flush
    @discardableResult public func pinText(_ text: String, richRTFD: Data?, title: String?, now: Date = Date()) -> HistoryItem?
        // budgets as record(); source nil; pinned from birth; if an unpinned item has identical text, pin THAT instead
}
```
`record`: if the de-dup match is pinned → return it unchanged. `enforceLimits`: count only
unpinned items against the cap; evict from the end skipping pinned items; the byte loop
likewise never evicts a pinned item. `clear()`: removes unpinned items and their blobs; keeps
pins; still removes quarantined indexes (they may name pins — accepted, pins re-save on
next mutation; flush after clear).

`HistorySearch.rank`: empty query → `pinnedItems + unpinnedItems` (tier 0); otherwise
haystack = `(title.map { $0 + "\n" } ?? "") + text.prefix(2048)`; sort by tier, then pinned
first, then original index. `HistorySearchResult` unchanged.

### Pastefix app

- **`FrontmostAppTracker`**: `private(set) var previousApp: NSRunningApplication?` —
  updated on each activation notification with the app that was current *before* the
  new one, when that app's bundle id differs from ours; `init` seeds it with the current
  frontmost app if that isn't us.
- **`SnippetPaster.swift`** (new, `@MainActor enum`):
  ```swift
  enum Outcome { case pasted, copiedOnly }
  static var isTrusted: Bool { AXIsProcessTrusted() }
  static func ensureTrusted() -> Bool   // prompts via AXIsProcessTrustedWithOptions once per launch
  static func paste(text: String, richRTFD: Data?, into app: NSRunningApplication?) -> Outcome
      // ClipboardBridge.write(text:richRTFD:imagePNG:nil); guard isTrusted else { _ = ensureTrusted(); return .copiedOnly }
      // reject nil/terminated/self as a target; else activate(from:.current) and schedule postWhenReady
      // postWhenReady polls every 20ms (1s deadline) until no blocking modifier is down AND the
      // target is frontmost, then posts ⌘V once via a .privateState CGEventSource — see Amendment 4
  static func openAccessibilitySettings()  // x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
  ```
- **`SnippetHotkeys.swift`** (new, `@MainActor final class`): owns `registered: Set<UUID>`;
  `sync(pins:)` registers `KeyboardShortcuts.onKeyUp(for: name(id))` for new ids (handler:
  look the item up by id in the store at fire time, then `SnippetPaster.paste(into: NSWorkspace.shared.frontmostApplication)`)
  and, for ids no longer pinned, `KeyboardShortcuts.reset(name)` followed by
  `KeyboardShortcuts.removeHandler(for: name)` — reset first, so a later re-pin of the same id
  starts with no recorded shortcut rather than inheriting the old binding. `static func
  name(for id: UUID) -> KeyboardShortcuts.Name` returns `snippet-<uuid>` (hyphen, not dot; see
  Amendment 1).
- **`AppDelegate`**: owns `snippetHotkeys`; calls `sync` at launch and on
  `history.$items` changes (debounced 200 ms, main queue, `removeDuplicates` on the set of
  pinned ids).
- **`AppModel`**: `func pinCurrentBuffer(title: String?)` → `history.pinText(doc.working, richRTFD: doc.origin.richRTFD, title:)`;
  `func togglePin(_ item:)`; `func pasteIntoPreviousApp(_ item: HistoryItem)` → resolves rich
  via `history.richRTFD(for:)`, `endSession()` (hides panel), then `SnippetPaster.paste(into: tracker.previousApp)`
  (the delegate injects a `previousAppProvider: () -> NSRunningApplication?`).
- **`HistoryOverlayView`**: when `query` is empty and pins exist, two `Section`s
  ("Pinned", "History") over one global index space; with a query, one flat list. Pinned
  rows: leading `pin.fill` glyph (accent colour), bold `title` line above the preview when
  set. Hidden key equivalents: ⌘P → `model.togglePin(selected)`; ⇧↵ → `pasteIntoPreviousApp`
  (a `Button` with `.keyboardShortcut(.return, modifiers: .shift)`, same pattern as ⌘⌫).
  Footer gains "⌘P Pin   ⇧↵ Paste". Empty state for "Pinned" isn't needed (section hidden).
- **`PanelView`** toolbar: pin button (`pin`), ⌘⇧P, opens a popover with a title field
  and "Pin" button; Enter pins.
- **`SettingsView`** → new `snippets` tab (`pin`): a `List` of `history.pinnedItems` with
  `TextField` bound through `rename`, caption preview, `KeyboardShortcuts.Recorder("", name: SnippetHotkeys.name(for: id))`,
  "Unpin". Header line: `SnippetPaster.isTrusted ? "Paste with hotkey: ready" : "Paste with hotkey needs Accessibility permission"`
  + "Open System Settings" button (+ "Request…" which calls `ensureTrusted`). Privacy tab's
  Clear History caption gains "Pinned snippets are kept."

## Data flow

Overlay, highlight a row, ⌘P → `pin` → row moves to the Pinned section → Settings → Snippets
→ type a title, record ⌃⌥S → back in Mail, press ⌃⌥S → clipboard = snippet → ⌘V posted →
text lands in Mail; the monitor sees the change, de-dup finds the pin, records nothing.
Editor: type boilerplate → ⌘⇧P → title "Sig" → pinned. Overlay ⇧↵ on any row → panel hides,
previous app activates, paste lands.

## Error handling

- Not trusted: `paste` writes the clipboard, triggers the system prompt once per launch,
  returns `.copiedOnly`; the overlay still hides (the user can ⌘V). Settings shows status.
- `previousApp` nil (nothing else ever activated) or terminated → copy-only.
- Hotkey for an id that was unpinned in this launch → no-op.
- `pinText` over budget → nil; the popover shows "Too large to pin" inline.
- Old index without `pinned`/`title` keys → decodes with defaults (test).

## Testing

`Tests/PastefixAppCoreTests/HistoryStoreTests` (extend): pin/unpin/rename; `pinText` new
vs existing-text promotion; de-dup no-op against a pin (count and order unchanged); cap
counts unpinned only (pins survive a cap of 1); byte eviction skips pins; `clear` keeps
pins and their blobs; `unpin` re-applies the cap; persistence round trip incl. `pinnedAt`
and `title`; a hand-written pre-Plan-9 index (no `pinned` key) loads with `pinned == false`.
`HistorySearchTests` (extend): empty query lists pins first newest-pinned; title matches;
tier tie → pin first. `HistoryFormattingTests`: unchanged.

Automated app pass (controller): ⌘⇧V, highlight, ⌘P → index shows `pinned: true`; relaunch
keeps it; cap 20 with 25 captures keeps the pin; editor ⌘⇧P with a title → pinned item with
title; Settings recorder can't be driven by AX reliably → bind the hotkey by writing the
KeyboardShortcuts UserDefaults entry for `snippet-<uuid>` (documented in the plan),
relaunch, open TextEdit, press the combo via System Events, read the TextEdit document →
text present (requires Accessibility granted to the Debug build — one manual click); ⇧↵ from
the overlay with TextEdit as the previous app pastes there. Screenshot: Pinned section.

## Documentation

- README: "Pinned snippets" section (pin from overlay/editor, Pinned section, ⇧↵ paste,
  per-snippet hotkeys, the Accessibility note and the copy-only fallback, Clear History
  keeps pins).
- AGENTS.md: layout (`SnippetPaster.swift`, `SnippetHotkeys.swift`); Patterns note: "Accessibility
  is requested only to post ⌘V; Pastefix never installs an event tap or reads keystrokes";
  status row.

## Project layout delta

```
Sources/PastefixAppCore/History/HistoryItem.swift      # pinned, pinnedAt, title; tolerant decoder
Sources/PastefixAppCore/History/HistoryStore.swift     # pin API; eviction/clear/dedup rules
Sources/PastefixAppCore/History/HistorySearch.swift    # pins first; title haystack
Pastefix/Pastefix/FrontmostAppTracker.swift            # previousApp
Pastefix/Pastefix/SnippetPaster.swift                  # new
Pastefix/Pastefix/SnippetHotkeys.swift                 # new
Pastefix/Pastefix/AppModel.swift                       # pinCurrentBuffer, togglePin, pasteIntoPreviousApp
Pastefix/Pastefix/HistoryOverlayView.swift             # sections, ⌘P, ⇧↵, pinned rows
Pastefix/Pastefix/PanelView.swift                      # pin button + popover
Pastefix/Pastefix/SettingsView.swift                   # Snippets tab; Clear History caption
Pastefix/Pastefix/PastefixApp.swift                    # SnippetHotkeys sync; previousApp injection
```
