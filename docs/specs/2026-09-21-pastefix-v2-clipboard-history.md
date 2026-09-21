---
type: spec
status: approved
id: 2026-09-21-pastefix-v2-clipboard-history
title: Pastefix v2 — Clipboard History (Plan 6)
description: Continuous pasteboard capture (text, rich text, images within a budget) into a persisted, capped history; a ⌘⇧V history overlay in the panel with fuzzy search, load-into-editor and copy-back; Settings for capture, size, and clearing; a CaptureFilter hook for the sensitive-app exclusions of issue #10.
tags: [pastefix, macos, swift, clipboard, history, privacy]
timestamp: 2026-09-21T00:30:00Z
---

# Pastefix v2 — Clipboard History (Plan 6)

Source: [issue #9](https://github.com/bnaylor/pastefix/issues/9) ("Multiple
clipboard items support (then I can delete CopyClip)", "Fuzzy search clipboard
history"), original requirements §4. Issue #10 (sensitive-app exclusion) builds
directly on the `CaptureFilter` hook defined here and follows as Plan 7.

## Scope

**In scope:**

- **Capture:** a `PasteboardMonitor` in the app target polls the general
  pasteboard's `changeCount` twice a second while capture is enabled and
  records each new item, unless it is marked concealed/transient/auto-generated
  or fails the `CaptureFilter`.
- **Model (`PastefixAppCore`, tested):** `HistoryItem`, `HistoryStore` (cap,
  budgets, de-duplication, eviction, persistence as an index plus per-item
  blobs, corrupt-file quarantine), `HistorySearch` (fuzzy ranking), preview and
  age formatters.
- **Representations:** plain text (inline, ≤ 256 KB), rich text as RTFD data
  (≤ 1 MB), image as PNG (≤ 5 MB); at least one present. 200 items and 50 MB
  on disk total.
- **Overlay:** a second rebindable hotkey (default ⌘⇧V) and a toolbar button
  (⌘Y) open a history overlay in the existing panel: search, ranked list with
  previews/thumbnails, ↵ loads text/rich items into the editor as a new
  session, ↵ on an image item copies it back, ⌘↵ copies any item back and
  dismisses, ⌘⌫ removes an item, Esc closes.
- **Settings:** History section on General (capture toggle, size stepper,
  Clear History); second recorder on Shortcut.
- `ClipboardBridge.write(_ item:)` writing all representations at once.
- README, AGENTS.md (new Critical Invariant), release-note text.

**Explicitly out of scope:**

- Bundle-id exclusion list UI (#10, Plan 7) — the hook is here, the list is not.
- Showing or editing images in the editor (#18); OCR (#19); image sanitisation
  (#20). Image items can only be previewed and copied back.
- Pinned snippets and text expansion (#17), though they will share the overlay.
- Sync, encryption at rest, or history of file URLs / other pasteboard types.
- Time-based expiry.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Capture default | On, from first launch after the update; a Settings toggle stops polling entirely | User's call. The concealed/transient skip ships in this plan, not deferred, so the default is safe for password managers on day one. |
| Detection mechanism | Poll `NSPasteboard.general.changeCount` every 0.5 s on the main run loop | macOS has no pasteboard change notification; every history app polls. A change-count read is a single cheap XPC call. |
| What is captured | Text, rich text (RTFD), image (PNG); at least one; within per-item and total budgets | User's call: rich text and images are valid things to revisit, and RTFD storage is what makes Markdown ↔ rich (#16) useful from history. |
| Budgets | 200 items; 256 KB text; 1 MB RTFD; 5 MB PNG; 50 MB total; evict oldest first | Proposed and accepted. Generous for text, enough for a page of formatted content or a screenshot, bounded on disk. |
| Storage layout | `history/index.json` (metadata + inline text) + `history/<uuid>.rtfd` / `<uuid>.png` blobs, under `~/Library/Application Support/Pastefix/` | Keeps the index small and human-inspectable; big payloads are never base64-encoded into JSON; a blob can be deleted independently. |
| Write strategy | Atomic (`.atomic`), owner-only permissions (0600 files, 0700 directory), debounced 250 ms after the last mutation | A crash mid-write cannot corrupt the index; other local users cannot read history. |
| De-duplication | Text items by exact plain text; image items by SHA-256 of the PNG; a duplicate moves to the top and refreshes `capturedAt` | Copying the same thing twice shouldn't consume two slots; the most recent copy is what the user expects at the top. |
| Source app | `NSWorkspace.shared.frontmostApplication` at capture time (bundle id + localized name) | Best available signal; exact for keyboard copies, approximate for background writers. Also what #10's filter keys on. |
| Our own Save writes | Recorded like any other change | They are clipboard contents; users revisit their own edits too. |
| Overlay host | The existing panel, an overlay shaped like the ⌘K palette | One window, one Esc model, one focus story. A second Spotlight-style window would duplicate all of that. |
| ↵ semantics | Text/rich: load into the editor as a new session (origin = the item, with `richRTFD` attached). Image: copy back and dismiss (row says "↵ copies") | Editing is the app's core; images can't be edited until #18, so ↵ does the only useful thing. |
| ⌘↵ semantics | Copy the whole item (all representations) to the clipboard and dismiss | The CopyClip use case: get an old item back onto the clipboard in two keystrokes. |
| Search | Same folding/tiers as `TransformSearch`, over the first 2 KB of plain text; empty query = recency order; image-only items match on their source app name and "image" | Consistent feel with ⌘K; bounded cost per keystroke. |
| Exclusion hook | `protocol CaptureFilter { func shouldCapture(_ candidate: CaptureCandidate) -> Bool }`; the monitor consults a list of filters; this plan ships `ConcealedTypeFilter` | #10 adds `BundleIDExclusionFilter` without touching the monitor. |
| Invariant | New Critical Invariant: concealed/transient pasteboard items are never recorded, and nothing in history is ever written anywhere but the owner-only history directory | Load-bearing for trust; belongs in AGENTS.md. |

## Architecture

### `PastefixAppCore`

**`History/HistoryItem.swift`** (new)

```swift
public struct HistoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var capturedAt: Date
    public let plainText: String?          // inline; ≤ 256 KB (UTF-8)
    public let richRTFDFile: String?       // "<uuid>.rtfd" in the history dir, ≤ 1 MB
    public let imageFile: String?          // "<uuid>.png", ≤ 5 MB
    public let imagePixelSize: CGSize?     // for the row caption
    public let imageHash: String?          // SHA-256 hex of the PNG, for de-dup
    public let sourceBundleID: String?
    public let sourceAppName: String?
    public var byteCount: Int              // text + blobs, for the total budget

    public var kind: Kind                  // .text, .richText (text + rtfd), .image (image, maybe text)
    public enum Kind: String, Codable, Sendable { case text, richText, image }
}
```

**`History/HistoryStore.swift`** (new) — `@MainActor public final class
HistoryStore: ObservableObject`.

```swift
public struct HistoryLimits: Sendable, Equatable {
    public var maxItems: Int = 200
    public var maxTextBytes: Int = 262_144
    public var maxRichBytes: Int = 1_048_576
    public var maxImageBytes: Int = 5_242_880
    public var maxTotalBytes: Int = 52_428_800
}

public struct CaptureCandidate: Sendable {
    public var plainText: String?
    public var richRTFD: Data?
    public var imagePNG: Data?
    public var sourceBundleID: String?
    public var sourceAppName: String?
}

public final class HistoryStore: ObservableObject {
    @Published public private(set) var items: [HistoryItem]      // newest first
    public var limits: HistoryLimits { didSet { enforceLimits() } }
    public init(directory: URL, limits: HistoryLimits = .init())  // loads index; quarantines a corrupt one
    @discardableResult public func record(_ candidate: CaptureCandidate) -> HistoryItem?
    public func remove(_ id: UUID)
    public func clear()
    public func richRTFD(for item: HistoryItem) -> Data?
    public func imagePNG(for item: HistoryItem) -> Data?
    public var totalBytes: Int
}
```

- `record` returns nil when the candidate has no usable representation after
  budget trimming (text over `maxTextBytes` is dropped, not truncated; rich
  over `maxRichBytes` is dropped while keeping the text; image over
  `maxImageBytes` is dropped), when the text is whitespace-only and there is no
  image, or when it duplicates the top item exactly (nothing to do). A
  duplicate further down moves to the top with a fresh `capturedAt`.
- `enforceLimits` trims to `maxItems`, then evicts oldest until
  `totalBytes ≤ maxTotalBytes`, deleting blobs for evicted items.
- Persistence: index written with `JSONEncoder` (ISO 8601 dates) to
  `index.json` via `Data.write(options: .atomic)`, then `chmod 0600`; blobs
  written atomically before the index that references them; the directory is
  created with 0700. Writes are debounced 250 ms via a `Task` that is cancelled
  and restarted on each mutation; `flush()` exists for tests and for
  `applicationWillTerminate`.
- Loading: a missing directory → empty store; an unreadable/undecodable index
  → renamed to `index.json.corrupt-<timestamp>` and an empty store; blobs
  referenced by the index but missing on disk → the item is kept with that
  representation cleared (a text item survives losing its RTFD; an image-only
  item with a missing PNG is dropped).
- I/O errors on write are logged (`os.Logger`, category "history") and the
  store keeps running in memory; the next mutation retries.
- Thread-safety: main-actor class; file I/O for the debounced write runs on a
  detached task with a snapshot of the index, never touching `items` off-main.

**`History/HistorySearch.swift`** (new)

```swift
public struct HistorySearchResult: Identifiable, Sendable {
    public let item: HistoryItem
    public var id: UUID { item.id }
    public let matchedRanges: [Range<String.Index>]   // into the preview text
    public let tier: Int
}
public enum HistorySearch {
    public static func rank(query: String, in items: [HistoryItem]) -> [HistorySearchResult]
}
```

Reuses `TransformSearch`'s folding and tier logic (extracted into a shared
internal `FuzzyMatch` helper so both call the same code): tier 1 prefix of the
haystack, tier 2 word start, tier 3 subsequence; the haystack is
`previewText` (below) capped at 2 048 characters; image-only items use
`"image \(sourceAppName ?? "")"` as their haystack. Ties keep recency order.
Empty query → all items, recency order, tier 0.

**`History/HistoryFormatting.swift`** (new) — pure helpers used by the row:
`previewText(for:)` (first two non-blank lines, whitespace collapsed, ≤ 160
characters, "…" when truncated; `"Image \(w)×\(h)"` for image-only items),
`relativeAge(from:to:)` ("now", "12s", "3m", "2h", "yesterday", "3d",
"Sep 14"), and `byteLabel(_:)` ("1.2 MB").

**`SettingsStore`** — `historyEnabled: Bool` (default true, key
`pastefix.historyEnabled`), `historyMaxItems: Int` (default 200, key
`pastefix.historyMaxItems`, clamped 20…1000).

### `Pastefix` app

**`PasteboardMonitor.swift`** (new) — `@MainActor final class`:

- `init(pasteboard: NSPasteboard = .general, filters: [any CaptureFilter], onCapture: @escaping (CaptureCandidate) -> Void)`.
- `start()` / `stop()` manage a `Timer` (0.5 s, main run loop, `.common` mode
  so it fires while menus are open). On each tick: if `changeCount` differs
  from the last seen value, read the pasteboard **once** into a
  `CaptureCandidate`:
  - Skip entirely if `types` contains any of `org.nspasteboard.ConcealedType`,
    `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`
    (`ConcealedTypeFilter`, first in the filter list).
  - `plainText = string(forType: .string)`; `richRTFD` from
    `readObjects(forClasses: [NSAttributedString.self])` **only if**
    `availableType(from: [.rtf, .rtfd, .html]) != nil` (the Plan 2a lesson),
    serialised to RTFD data; `imagePNG` from `.png` directly, else from `.tiff`
    via `NSBitmapImageRep` → PNG; `imagePixelSize` from the rep.
  - Consult every `CaptureFilter`; if all say yes, call `onCapture`.
  - The first tick after `start()` only records the current `changeCount`; it
    does not capture what was already on the clipboard.
- `protocol CaptureFilter: Sendable { func shouldCapture(_ candidate: CaptureCandidate, types: [NSPasteboard.PasteboardType]) -> Bool }` and
  `struct ConcealedTypeFilter: CaptureFilter`.

**`AppDelegate`** — owns `HistoryStore(directory: <Application Support>/Pastefix/history)`
and the monitor; starts the monitor when `settings.historyEnabled` is true and
re-points it on change (same sink pattern as `showSidebar`); calls
`historyStore.flush()` in `applicationWillTerminate`. Registers the second
hotkey `KeyboardShortcuts.Name.summonHistory` (default ⌘⇧V) →
`summonHistory()`: if no session, `model.summon()` first (so the editor has
the current clipboard behind the overlay), then `isHistoryOpen = true` via a
published flag on `AppModel` (`showHistoryRequested`) that `PanelView`
observes.

**`AppModel`** — gains `let history: HistoryStore` (injected),
`func load(_ item: HistoryItem)` (bumps `sessionGeneration`, sets
`document = PasteDocument(origin: ClipboardSnapshot(plainText: item.plainText ?? "", richRTFD: history.richRTFD(for: item)))`),
`func copyBack(_ item: HistoryItem)` (`ClipboardBridge.write(item, from: history)` then `endSession()`),
and `@Published var historyOverlayRequested = false`.

**`ClipboardBridge`** — `static func write(text: String?, richRTFD: Data?, imagePNG: Data?)`:
`clearContents()`, then `setString` for text, `setData(_, forType: .rtfd)`
(and `.rtf` derived from the attributed string) for rich, `setData(_, forType: .png)`
for images. Existing `writePlain` remains and calls it.

**`HistoryOverlayView.swift`** (new) — same chrome as `CommandPaletteView`
(shared `PanelMetrics`), title "History", search field focused on open,
`List` of `HistorySearchResult` rows:

- Text/rich row: two-line monospaced preview with highlighted match, trailing
  caption "`<app>` · `<age>`", a small "rich" badge when RTFD is present.
- Image row: 44×44 thumbnail (`NSImage(data:)` cached per id), caption
  "Image 1280×800 · Screenshot · 3m", trailing hint "↵ copies".
- Keys: ↑↓ wrap; ↵ → `model.load(item)` (text/rich) or `model.copyBack(item)`
  (image); ⌘↵ → `model.copyBack(item)`; ⌘⌫ → `history.remove(item.id)`;
  Esc → close. All handlers read live `@State` (the Plan 4 lesson).
- Empty states: "No clipboard history yet" / "Clipboard history is off — enable
  it in Settings" (with a button that opens Settings) / "No matches".
- Footer: "↵ Open   ⌘↵ Copy   ⌘⌫ Remove   esc Close".

**`PanelView`** — `@State isHistoryOpen`; toolbar clock button (`clock.arrow.circlepath`,
⌘Y) toggles it; the overlay `ZStack` hosts either the palette or the history
overlay (never both; opening one closes the other); Esc arbitration: Cancel's
action closes the palette if open, else the history overlay if open, else
cancels. Observes `model.historyOverlayRequested` to open on ⌘⇧V.

**`SettingsView`** — General: `Section("History")` with
`Toggle("Remember clipboard history")`, `Stepper("Keep last \(n) items")`
(20…1000, step 10), `Button("Clear History…")` with a confirmation alert
showing the item count and total size; Shortcut tab: second
`KeyboardShortcuts.Recorder("Open history:", name: .summonHistory)`.

## Data flow

Copy in Safari → 0–0.5 s later the monitor sees a new `changeCount` → builds a
candidate (text + RTFD) → `ConcealedTypeFilter` passes → `history.record` →
item at the top, index write scheduled → ⌘⇧V → panel appears with the current
clipboard in the editor and the history overlay open → type "invoice" → ranked
list → ↵ → `model.load(item)` → new session with rich data → "Rich → Plain
Text" available → Save writes plain text → the monitor records that too.
Screenshot → PNG candidate → thumbnail row → ⌘↵ → PNG back on the clipboard,
panel hides.

## Error handling

- Pasteboard reads can throw or return nil under contention; the monitor
  treats any failure as "nothing to capture this tick" and never retries the
  same `changeCount`.
- Store write failures are logged and non-fatal; a full disk shows a one-line
  banner in the overlay ("History couldn't be saved") on the next open.
- A blob missing at read time degrades the item (see loading rules); the UI
  never crashes on a missing file.
- Image decoding failures on copy-back fall back to copying the text
  representation if present, else show the banner.

## Testing

`Tests/PastefixAppCoreTests/` (all against a temporary directory, cleaned up):

- `HistoryStoreTests`: record text/rich/image; newest-first; cap trims oldest
  and deletes blobs; total-byte eviction; per-representation budgets (oversize
  text dropped, oversize rich dropped but text kept, oversize image dropped);
  whitespace-only text ignored; exact duplicate at top is a no-op; duplicate
  further down moves to top with new date; image de-dup by hash; `remove`
  deletes blobs; `clear` empties directory; persistence round-trip through a
  second store instance; corrupt index quarantined with `.corrupt-` prefix;
  missing blob degrades/drops correctly; `limits` change re-enforces; index and
  blob files have 0600 permissions and the directory 0700; `flush` writes
  synchronously.
- `HistorySearchTests`: empty query recency order; prefix/word-start/
  subsequence tiers over the preview; image-only items match "image" and the
  app name; haystack cap at 2 048 chars; highlight ranges valid.
- `HistoryFormattingTests`: preview first two non-blank lines, whitespace
  collapse, 160-char truncation with "…", image caption; relative ages at each
  boundary; byte labels.
- `FuzzyMatchTests` (if extracted): `TransformSearch` tests keep passing
  unchanged.
- `SettingsStoreTests`: the two new keys, defaults and clamping.

`Tests/PastefixCoreTests/`: none (nothing in the engine changes).

Manual (app): capture on by default after launch; copy text in another app →
appears within a second; copy formatted text in a browser → "rich" badge, ↵
loads it and Rich → Plain Text is enabled; take a screenshot (⌘⇧⌃4 copies) →
thumbnail row, ↵ and ⌘↵ put the PNG back (paste into Preview); copy a password
from a password manager → not recorded; ⌘⇧V with no session opens the overlay
over the current clipboard; ⌘Y from inside the panel; ⌘⌫ removes; Esc closes
the overlay, second Esc cancels; Clear History empties the list and the
directory; toggling capture off stops new items; relaunch preserves history;
`ls -l` on the history directory shows 0600/0700.

## Documentation

- `README.md`: a "Clipboard history" section (what is captured, the budgets,
  ⌘⇧V / ⌘Y, ↵ vs ⌘↵, the concealed-type rule, where the files live, how to
  clear or disable); Settings section updated; the release note text for the
  Sparkle release page: "Pastefix now keeps a history of what you copy…" with
  the opt-out.
- `AGENTS.md`: layout entries (`History/` in AppCore; `PasteboardMonitor.swift`,
  `HistoryOverlayView.swift`); build/test notes on the temp-directory tests;
  **new Critical Invariant 12:** *Clipboard history never records items marked
  concealed/transient/auto-generated, never stores anything outside the
  owner-only history directory, and every capture passes through the
  `CaptureFilter` chain — new capture sources or storage paths must keep all
  three.* Plus a Patterns note: the monitor reads the pasteboard once per
  change and never on a timer tick without a change.
- Spec for #10 (Plan 7) will reference `CaptureFilter` and `sourceBundleID`.

## Project layout delta

```
Sources/PastefixAppCore/
  History/HistoryItem.swift
  History/HistoryStore.swift
  History/HistorySearch.swift          # + internal FuzzyMatch shared with TransformSearch
  History/HistoryFormatting.swift
  SettingsStore.swift                  # + historyEnabled, historyMaxItems
Pastefix/Pastefix/
  PasteboardMonitor.swift              # polling + CaptureFilter chain + ConcealedTypeFilter
  HistoryOverlayView.swift
  HotkeyName.swift                     # + summonHistory (⌘⇧V)
  ClipboardBridge.swift                # + write(text:richRTFD:imagePNG:)
  AppModel.swift                       # + history, load(_:), copyBack(_:), historyOverlayRequested
  PanelView.swift                      # + history overlay host, ⌘Y, Esc arbitration
  PastefixApp.swift                    # + store, monitor, second hotkey, flush on terminate
  SettingsView.swift                   # + History section, second recorder
```

## Open questions / future increments

- #10: `BundleIDExclusionFilter` + Settings list (Plan 7).
- #17: pinned snippets in the same overlay.
- #18/#19/#20: image viewing, OCR, and EXIF stripping on history images.
- #16: rich → Markdown, which history now feeds.
- Encryption at rest if history ever leaves the local user account.
