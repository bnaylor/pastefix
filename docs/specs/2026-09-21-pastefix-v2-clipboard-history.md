---
type: spec
status: implemented
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

## Amendments (post-implementation)

The sections below are updated in place to match what shipped; this list is
the summary of what changed and why, for anyone comparing against an earlier
read of this spec.

1. **Duplicate-at-top is a true no-op.** `HistoryStore.record` returns the
   existing item unchanged (not `nil`) when the candidate duplicates the item
   already at index 0. A duplicate further down moves to the top with a fresh
   `capturedAt` but **keeps its original `sourceBundleID`/`sourceAppName`**:
   re-copying an item (e.g. `AppModel.copyBack`) re-writes the pasteboard, and
   the monitor would otherwise relabel a reused item as coming from Pastefix
   itself.
2. **Index writes run on a private serial `DispatchQueue`, not a detached
   `Task`.** The queue is FIFO, so an older snapshot can never land after a
   newer one. `flush()` enqueues the write and blocks until the queue drains.
   `remove`, `clear`, and any limit trim that evicts write synchronously
   (`flush()`); only `record` debounces (250 ms). `lastWriteError` is
   `@Published` and eventually consistent — it updates on a later main-actor
   turn than the mutation that triggered the write.
3. **Blob names are always derived from the item id.** At load, any
   index-referenced name that doesn't match `<id>.<ext>`, or that names a
   missing file, is treated as missing. Unreferenced blobs are swept at load
   *except* on the launch that quarantines a corrupt index — that index is the
   only record of which blob belongs to which item, so sweeping then would
   delete the payloads the quarantine exists to let a human recover.
   `byteCount` is always recomputed from what's actually on disk at load,
   never trusted from the index. Item-cap eviction never evicts below one
   item.
4. **`CaptureFilter` is two-stage.** `shouldRead(types:)` runs on declared
   types alone before any content is read; `shouldCapture(_:types:)` runs
   again after the read, on the full candidate, with the pasteboard's change
   count re-checked first — a mismatch discards the read rather than recording
   a mixed candidate. Stage 2 sees the **union of the types sampled before and
   after the read**: `setData`/`setString` do not bump `changeCount`, so an
   unchanged count proves only that the change did not turn over, not that the
   type list is unchanged, and a marker added to the same change after the
   first sample would otherwise be invisible to both stages. The concealed
   marker check also covers three legacy spellings still emitted by older
   apps. A tick that sees empty declared types is retried next tick rather
   than treated as a real (empty) change. PNG over the image budget is
   skipped before decoding; TIFF is gated by a header-only pixel count (>25M
   pixels skipped) before paying for a decode + PNG re-encode, and that decode
   and re-encode runs off the main actor (Amendment 9) because a TIFF's PNG
   size is unknown until the PNG exists — so the change-count re-check and the
   stage-2 filter pass both happen a second time, after it.
5. **The store is constructed with the user's configured cap directly**, and
   cap changes from Settings are clamped and debounced 400 ms in the app layer
   before reaching `HistoryStore.limits`, so holding the Settings stepper
   doesn't walk the store through every intermediate value.
6. **Overlay implementation details:** ⌘⌫ is a hidden key-equivalent `Button`
   (`onKeyPress` would be swallowed by the search field's field editor).
   Visible rows derive from the panel's available height (4 at the panel
   minimum, up to 8), not a fixed 8. Thumbnails are ImageIO thumbnails
   downsampled to max 88 px, cached up to 64 with FIFO eviction. The overlay
   closes *before* `load`/`copyBack` runs. An image-only item's ↵ copies back
   instead of opening an empty editor; `AppModel.load` redirects image-only
   items to `copyBack` for the same reason.
7. **⌘⇧V shadows "Paste and Match Style"** in apps that bind that command to
   the same combination. Kept by decision — it's the natural mnemonic and the
   hotkey is rebindable in Settings → Shortcut.
8. **Polling limit on the concealed guarantee.** The monitor honours a
   concealed/transient marker that is present when it reads the item, and the
   stage-2 filter re-samples types after the read. A marker an app adds only
   *after* our tick has already read and recorded the item cannot be honoured;
   real password managers write the marker in the same burst as the content,
   which is covered. Verified in the manual pass: same-burst and legacy markers
   are skipped; a marker delayed by 700 ms was not.
9. **TIFF→PNG conversion runs off the main actor** (#32; deferred out of the
   original build, done later). A photographic TIFF inside the pixel ceiling
   costs 0.4 s (6.6 MP) to 1.3 s (20.4 MP) to decode and re-encode, often for a
   PNG the image budget then discards, and the poll timer runs in `.common`
   mode, so on the main actor that stall lands during menu tracking. `read`
   therefore returns the raw TIFF plus its header pixel size and converts
   nothing; `tick` runs stage 2 as usual (provisionally — the candidate has no
   image yet) and then hands the bytes to the conversion lane (only `Data` and
   `Int` cross), and the capture happens from the completion, back on the main
   actor. Everything that can change while the conversion runs is decided there
   and not before: the change count is re-checked, and the stage-2 filters run
   again over the types approved earlier *unioned with those declared now* —
   `setData` still doesn't bump the change count, and the conversion window is
   far wider than the read's. A pasteboard that turned over drops the item.
   That is kin to the post-read check but not the same loss: there the
   candidate mixes two changes and is worthless, here the bytes are clean and
   what is lost is the ability to re-verify them — `pasteboard.types` now
   describes a different change, so the late-marker check cannot be performed
   at all, and recording anyway would file an older image above the thing the
   user copied after it. Both drops are logged (`os.Logger`, category
   "history") at `.notice`, since nothing else would show them and `.debug` is
   neither persisted nor present in the default release stream. Attribution
   stays the pre-conversion sample, since the source app is determined before
   the read and a second later the newest activation may be an app the user
   switched to after copying; only the exclusion check gets the widened set of
   recent bundle ids — which means switching to an *excluded* app during the
   conversion window drops a capture the pre-conversion pass had approved,
   accepted as the fail-closed direction. At most one conversion runs at a time
   process-wide: `TIFFConversionSlot.shared` is one lane with one waiting slot,
   and one superseded before it starts (by a newer change or by `stop()`, both
   via the generation number) is skipped, while one already running finishes
   anyway because `NSBitmapImageRep` offers no cancellation point — cancelling
   the wrapper task would not have bounded the work, which is why the lane
   exists. The lane holds a single waiter rather than a queue, and a second
   arrival displaces the one waiting: queueing would have bounded the
   concurrent decodes while leaving every queued block holding its own source
   TIFF, so a burst would keep three TIFFs alive waiting for one decode instead
   of running three at once. Peak is two TIFFs and one bitmap. It is shared
   rather than owned by the monitor because editing the exclusion list rebuilds
   `PasteboardMonitor`, and a per-instance lane would let the outgoing
   monitor's in-flight decode run alongside the incoming one's; the generation
   counter is minted by the lane for the same reason, so that a rebuilt monitor
   supersedes its predecessor's pending work rather than racing it with a
   colliding number. A conversion that fails or produces a PNG over the
   budget records the item's text if it has any and nothing otherwise —
   `PendingImage.resolve` in `PastefixAppCore`, the one testable piece of this.
   The overlay's thumbnail blob read and ImageIO decode moved off the main
   actor the same way, keyed by item id: the decoded image is installed for the
   id it was loaded for whether or not the row that asked for it survived, or a
   row filtered out mid-load and brought straight back would sit on the grey
   placeholder for good. A blob that will not decode is a different thing from
   a slow one — `HistoryStore` sets `imageFile` only after an atomic write, so
   a failure means missing or corrupt — and is logged once and remembered for
   the session rather than re-read on every appearance.

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
| Write strategy | Atomic (`.atomic`), owner-only permissions (0600 files, 0700 directory), on a private serial `DispatchQueue`; `record` debounces 250 ms, `remove`/`clear`/evicting trims write synchronously via `flush()` (Amendment 2) | A crash mid-write cannot corrupt the index; other local users cannot read history; a user-initiated delete or an eviction that already deleted blobs cannot be lost to a crash inside the debounce window. |
| De-duplication | Text items by exact plain text; image items by SHA-256 of the PNG; a duplicate elsewhere moves to the top and refreshes `capturedAt` (but keeps its original source app — Amendment 1); a duplicate already at the top is a no-op | Copying the same thing twice shouldn't consume two slots; the most recent copy is what the user expects at the top. |
| Source app | `NSWorkspace.shared.frontmostApplication` at capture time (bundle id + localized name) | Best available signal; exact for keyboard copies, approximate for background writers. Also what #10's filter keys on. |
| Our own Save writes | Recorded like any other change | They are clipboard contents; users revisit their own edits too. |
| Overlay host | The existing panel, an overlay shaped like the ⌘K palette | One window, one Esc model, one focus story. A second Spotlight-style window would duplicate all of that. |
| ↵ semantics | Text/rich: load into the editor as a new session (origin = the item, with `richRTFD` attached). Image: copy back and dismiss (row says "↵ copies") | Editing is the app's core; images can't be edited until #18, so ↵ does the only useful thing. |
| ⌘↵ semantics | Copy the whole item (all representations) to the clipboard and dismiss | The CopyClip use case: get an old item back onto the clipboard in two keystrokes. |
| Search | Same folding/tiers as `TransformSearch`, over the first 2 KB of plain text; empty query = recency order; image-only items match on their source app name and "image" | Consistent feel with ⌘K; bounded cost per keystroke. |
| Exclusion hook | `protocol CaptureFilter { func shouldRead(types:) -> Bool; func shouldCapture(_ candidate:, types:) -> Bool }` (two-stage — Amendment 4); the monitor consults a list of filters at each stage; this plan ships `ConcealedTypeFilter` | #10 adds `BundleIDExclusionFilter` without touching the monitor. |
| Invariant | New Critical Invariant: concealed/transient pasteboard items are never recorded, and nothing in history is ever written anywhere but the owner-only history directory | Load-bearing for trust; belongs in AGENTS.md. |

## Architecture

### `PastefixAppCore`

**`History/HistoryItem.swift`** (new)

```swift
public struct HistoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var capturedAt: Date
    public var plainText: String?          // inline; ≤ 256 KB (UTF-8)
    public var richRTFDFile: String?       // "<uuid>.rtfd" in the history dir, ≤ 1 MB
    public var imageFile: String?          // "<uuid>.png", ≤ 5 MB
    public var imagePixelWidth: Int?       // for the row caption; header-derived, no CGSize (AppCore stays AppKit/CoreGraphics-free)
    public var imagePixelHeight: Int?
    public var imageHash: String?          // SHA-256 hex of the PNG, for de-dup
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var byteCount: Int              // text + blobs, for the total budget

    public var kind: Kind                  // .text, .richText (text + rtfd), .image (image, maybe text)
    public enum Kind: String, Codable, Sendable { case text, richText, image }
    public var hasText: Bool               // plainText, trimmed, is non-empty
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
    public var imagePixelWidth: Int?
    public var imagePixelHeight: Int?
    public var sourceBundleID: String?
    public var sourceAppName: String?
}

public final class HistoryStore: ObservableObject {
    @Published public private(set) var items: [HistoryItem]      // newest first
    // Lowering a limit sheds items and deletes blobs immediately, so that trim must be
    // flushed rather than debounced (Amendment 2); otherwise it schedules the normal debounced write.
    public var limits: HistoryLimits { didSet { if enforceLimits() { flush() } else { scheduleWrite() } } }
    @Published public private(set) var lastWriteError: String?   // eventually consistent — see Amendment 2
    public let directory: URL
    public init(directory: URL, limits: HistoryLimits = .init())  // loads index; quarantines a corrupt one
    @discardableResult public func record(_ candidate: CaptureCandidate, now: Date = Date()) -> HistoryItem?
    public func remove(_ id: UUID)
    public func clear()
    public func richRTFD(for item: HistoryItem) -> Data?
    public func imagePNG(for item: HistoryItem) -> Data?
    public var totalBytes: Int
    public func flush()   // synchronous; tests, remove/clear, applicationWillTerminate
}
```

- `record` returns nil when the candidate has no usable representation after
  budget trimming (text over `maxTextBytes` is dropped, not truncated; rich
  over `maxRichBytes` is dropped while keeping the text; image over
  `maxImageBytes` is dropped), or when the text is whitespace-only and there is
  no image. When it duplicates the top item exactly, `record` is a true no-op:
  it returns the existing item, unchanged. A duplicate further down moves to
  the top with a fresh `capturedAt` but **keeps its original source app** — see
  Amendment 1.
- `enforceLimits` trims to `maxItems` (never below 1 item), then evicts oldest
  until `totalBytes ≤ maxTotalBytes`, deleting blobs for evicted items.
- Persistence: index written with `JSONEncoder` (ISO 8601 dates, sorted keys)
  to `index.json` via `Data.write(options: .atomic)`, then `chmod 0600`; blobs
  written atomically before the index that references them; the directory is
  created with 0700. A snapshot of `items` is encoded and written on a private
  serial `DispatchQueue` (FIFO — an older snapshot can never overwrite a newer
  one), debounced 250 ms after the last mutation from `record`. `remove`,
  `clear`, and any limit trim that evicts write synchronously via `flush()`,
  which enqueues the write and blocks until the queue drains — see Amendment 2.
  `flush()` is also called from `applicationWillTerminate`.
- Loading: a missing directory → empty store; an unreadable/undecodable index
  → renamed to `index.json.corrupt-<unix-seconds>` and an empty store; blobs
  referenced by the index but missing on disk, or named anything other than
  `<id>.<ext>`, are treated as missing and the item is kept with that
  representation cleared (a text item survives losing its RTFD; an image-only
  item with a missing PNG is dropped). `byteCount` is always recomputed from
  what's actually on disk, never trusted from the index. Blobs not referenced
  by any surviving item are swept at load, except on the launch that
  quarantines a corrupt index — see Amendment 3.
- I/O errors on write are logged (`os.Logger`, category "history") and update
  `@Published var lastWriteError: String?`; the store keeps running in memory
  and the next mutation retries. `lastWriteError` is eventually consistent —
  it lands on a later main-actor turn than the mutation that triggered the
  write, since the write itself runs off-main.
- Thread-safety: main-actor class; encoding and file I/O for every index write
  run on the serial writer queue with a snapshot of `items`, never touching
  `items` off-main.

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

- `init(pasteboard: NSPasteboard = .general, filters: [any CaptureFilter], maxImageBytes: Int, onCapture: @escaping (CaptureCandidate) -> Void)`.
- `start()` / `stop()` manage a `Timer` (0.5 s, main run loop, `.common` mode
  so it fires while menus are open). On each tick, if `changeCount` differs
  from the last seen value and declared `types` is non-empty (an empty read
  means a writer is mid-`clearContents()`/`setData` sequence; retry next
  tick without advancing `lastChangeCount`):
  - **Stage 1 — `shouldRead(types:)`:** a cheap gate on declared types alone,
    before any content is read, so a concealed item's bytes are never even
    read under the guise of deciding whether they may be captured.
    `ConcealedTypeFilter` (first in the filter list) rejects
    `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`,
    `org.nspasteboard.AutoGeneratedType`, and three legacy marker spellings
    still emitted by older apps: `de.petermaurer.TransientPasteboardType`,
    `com.typeit4me.clipping`, `Pasteboard generator type`.
  - Read the pasteboard **once** into a `CaptureCandidate`: `plainText =
    string(forType: .string)`; `richRTFD` from `readObjects(forClasses:
    [NSAttributedString.self])` **only if** `availableType(from: [.rtf,
    .rtfd, .html]) != nil` (the Plan 2a lesson), serialised to RTFD data;
    `imagePNG` from `.png` directly (skipped before decoding if over
    `maxImageBytes`); a `.tiff`-only image is carried out of the read
    unconverted, gated by a header-only pixel count (>25M pixels skipped,
    since TIFF byte size does not correlate with PNG-compressed size) and
    converted to PNG off the main actor afterwards (Amendment 9);
    `imagePixelWidth`/`imagePixelHeight` read from the image header, no full
    decode required.
  - If the pasteboard's `changeCount` changed again while the read was in
    flight, discard the read (it may mix this change's marker types with a
    later change's content) and roll `lastChangeCount` back one so the next
    tick reprocesses the newer change cleanly.
  - **Stage 2 — `shouldCapture(_:types:)`:** a gate on the full candidate,
    using the union of the types sampled before and after the read (see
    Amendment 4), for filters that need content `read` alone populates (e.g.
    `sourceBundleID`, for #10's app exclusion). If every filter says yes, call
    `onCapture` — unless the image is still an unconverted TIFF, in which case
    the conversion's completion calls it, after re-running both checks
    (Amendment 9).
  - The first tick after `start()` only records the current `changeCount`; it
    does not capture what was already on the clipboard.
- `protocol CaptureFilter: Sendable { func shouldRead(types: [NSPasteboard.PasteboardType]) -> Bool; func shouldCapture(_ candidate: CaptureCandidate, types: [NSPasteboard.PasteboardType]) -> Bool }`
  and `struct ConcealedTypeFilter: CaptureFilter` (implements both stages
  identically, since a concealed marker is decided by types alone). See
  Amendment 4.

**`AppDelegate`** — constructs `HistoryStore(directory: <Application
Support>/Pastefix/history, limits: HistoryLimits(maxItems:
settings.historyMaxItems))` directly with the user's configured cap (not the
default, reset afterward) and owns the monitor; starts the monitor when
`settings.historyEnabled` is true and re-points it on change (same sink
pattern as `showSidebar`); calls `historyStore.flush()` in
`applicationWillTerminate`. Registers the second hotkey
`KeyboardShortcuts.Name.summonHistory` (default ⌘⇧V — see Amendment 7) →
`summonHistory()`: if no session, `model.summon()` first (so the editor has
the current clipboard behind the overlay), then
`model.historyOverlayRequested = true`, which `PanelView` observes. Cap
changes from `settings.$historyMaxItems` are clamped (20…1000) and debounced
400 ms before being applied to `history.limits.maxItems`, so holding the
Settings stepper's arrow doesn't walk the store through every intermediate
value, evicting and deleting blobs at each step (Amendment 5).

**`AppModel`** — gains `let history: HistoryStore` (injected),
`func load(_ item: HistoryItem)` (bumps `sessionGeneration`, sets
`document = PasteDocument(origin: ClipboardSnapshot(plainText: item.plainText ?? "", richRTFD: history.richRTFD(for: item)))`
— except an image-only item, which has no text to edit: `load` redirects
those straight to `copyBack` instead of opening an empty session),
`func copyBack(_ item: HistoryItem)` (`ClipboardBridge.write(text:richRTFD:imagePNG:)` then `endSession()`),
and `@Published var historyOverlayRequested = false`.

**`ClipboardBridge`** — `static func write(text: String?, richRTFD: Data?, imagePNG: Data?)`:
`clearContents()`, then `setString` for text, `setData(_, forType: .rtfd)`
(and `.rtf` derived from the attributed string) for rich, `setData(_, forType: .png)`
for images. Existing `writePlain` remains and calls it.

**`HistoryOverlayView.swift`** (new) — same chrome as `CommandPaletteView`
(shared `PanelMetrics`), search field focused on open, `List` of
`HistorySearchResult` rows:

- Text/rich row: two-line monospaced preview with highlighted match, trailing
  caption "`<app>` · `<age>`", a small "rich" badge when RTFD is present.
- Image row: 44×44 thumbnail, trailing hint "↵ copies". Thumbnails are ImageIO
  thumbnails (`CGImageSourceCreateThumbnailAtIndex`, not a full decode)
  downsampled to a maximum of 88 px (2× the 44pt slot, for Retina), cached per
  item id up to 64 images with FIFO eviction — see Amendment 6. The blob read
  and the decode both run off the main actor (Amendment 9); the result is
  installed by item id, and a load already in flight for that id is not
  started twice.
- Visible row count derives from the panel's available height at open time,
  not a fixed 8: 4 rows at the panel's minimum height, up to a cap of 8.
- Keys: ↑↓ wrap; ↵ → `model.load(item)` (text/rich) or `model.copyBack(item)`
  (image); ⌘↵ → `model.copyBack(item)`; ⌘⌫ → `history.remove(item.id)`;
  Esc → close. All handlers read live `@State` (the Plan 4 lesson). ⌘⌫ is a
  hidden key-equivalent `Button`, not an `onKeyPress` handler — the search
  field's field editor implements `deleteToBeginningOfLine:` and would
  otherwise consume ⌘⌫ before the view ever sees it. Opening or copying back
  an item closes the overlay *first*, then calls `model.load`/`copyBack` —
  not the reverse — so a synchronous session-ending copy-back never races the
  overlay's own teardown.
- Empty states: "No clipboard history yet" / "Clipboard history is off — enable
  it in Settings" (with a button that opens Settings) / "No matches".
- Footer: "↵ Open   ⌘↵ Copy   ⌘⌫ Remove   esc Close" plus an item count and
  total size.

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
  `HistoryOverlayView.swift`, `FuzzyMatch.swift`); build/test notes on the
  temp-directory tests; **new Critical Invariant 12** naming the two-stage
  `CaptureFilter` chain explicitly (Amendment 4) — new capture sources,
  filters, or storage paths must keep `shouldRead`, `shouldCapture`, and the
  owner-only directory guarantee all three. Plus a Patterns note: the monitor
  reads the pasteboard once per `changeCount` change and never on a bare
  timer tick, and rich content is read only when a rich type is declared.
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

- #10: ~~`BundleIDExclusionFilter` + Settings list (Plan 7).~~ Resolved by [Plan 7](2026-09-21-pastefix-v2-sensitive-app-exclusion.md) (`AppExclusionFilter`, `FrontmostAppTracker`, Privacy tab, menu-bar pause).
- #17: pinned snippets in the same overlay.
- #18/#19/#20: image viewing, OCR, and EXIF stripping on history images.
- #16: rich → Markdown, which history now feeds.
- Encryption at rest if history ever leaves the local user account.
