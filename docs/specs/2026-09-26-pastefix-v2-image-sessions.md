---
type: spec
status: approved
id: 2026-09-26-pastefix-v2-image-sessions
title: Pastefix v2 — Image Sessions (Plan 15)
description: A session can hold, display and write back an image. `ClipboardSnapshot` gains an image field, `Transformer` declares what content it accepts, and ↵ on an image history row opens it like any other. Viewing only — editing, OCR, EXIF stripping and image upload all build on this.
tags: [pastefix, macos, swift, images, clipboard, transforms]
timestamp: 2026-09-26T18:00:00Z
---

# Pastefix v2 — Image Sessions (Plan 15)

Source: [issue #18](https://github.com/bnaylor/pastefix/issues/18) ("Support for
images — viewing initially, then trivial editing"), original requirements
"Later" tier.

**This is the enabler, and it is on the critical path to something already
shipped.** Plan 13 shipped Zipline upload for text and code; the repo owner's
framing is that *images are the main point of Zipline upload*. So this sits
under #48 (image upload) via #20 (EXIF stripping, which gates uploads), and it
also unblocks #19 (OCR) and #21 (format conversion). Five issues are behind it.

## What the app does today

Images already flow through capture, history and the clipboard. `HistoryStore`
writes PNG blobs and serves them by id, the ⌘⇧V overlay renders thumbnails, and
`ClipboardBridge.write(text:richRTFD:imagePNG:)` puts them back.

What cannot happen is a *session* holding one. `ClipboardSnapshot` carries
`plainText`, `richRTFD` and `changeCount` — there is no image field at all — and
`PasteDocument` is a text document (`history: [String]`, `working: String`).
`AppModel.load` refuses an image-only history item outright, with a comment
saying that opening a session "would silently discard the image".

So the gap is the document model, not the rendering.

## Scope

**In scope:**

- `ClipboardSnapshot` gains `imagePNG: Data?`, so a session can carry an image.
- The panel displays an image when the session has one and no text.
- Save / ⌘↵ writes back everything the session holds.
- `Transformer` declares what content it accepts; the palette and sidebar filter
  on it. **Zero image transforms ship here** — the declaration exists so #20 is
  the first one and validates the shape against a real consumer.
- ↵ on an image row in the history overlay opens it, like every other row.

**Out of scope:**

- **Editing** — crop, resize, annotate. #18 bundles it and its own text says
  "later"; it unblocks nothing, and by the time it is designed the model it
  needs already exists. Split to its own issue.
- Image transforms of any kind: EXIF stripping (#20), OCR (#19), format
  conversion and QR (#21), image upload (#48).
- Script image compatibility (#67) — the `Transformer` declaration covers
  script-derived transforms for free, but carrying bytes through `ShellRunner`
  is five separate pieces of work.
- Any change to what history stores or how much.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Image field's home | On `ClipboardSnapshot`, beside `plainText` and `richRTFD` | It is the missing third content field, not a new concept. Every existing reader of a snapshot keeps working. |
| Format | PNG | #32's `TIFFConversionSlot` already normalises TIFF→PNG on the capture path. A second decode path would be a second place for the 25 M-pixel ceiling and the conversion lane to drift. |
| Mixed clipboard | Carry both; display by content | A clipboard with an image *and* text (copying an image from a browser gives you both) keeps opening the text editor exactly as today, so no text workflow regresses — but the image stays on the session, reachable by image-aware actions. Rejected "image wins": a rich snippet that happens to carry an image preview would stop opening the editor, and that is the app's core use. |
| Session document type | `PasteDocument` gains the image; no session enum | A `.text`/`.image` enum cannot represent a clipboard that carries both, which the decision above requires. It would also make every consumer of `document` unwrap for one real case. |
| Text state | `working: String` and `history: [String]` unchanged | The transform pipeline, undo/redo, detection and secret scanning all read `working` and none of them should learn about images. |
| Undo in an image session | Nothing to undo; `canUndo` is false | Not a new meaning for undo — an image session has no text history, and inventing image undo here is the editing feature this spec excludes. |
| What counts as "no text" | Blank once trimmed is not text — the same rule `PendingImage.resolve` and `HistoryStore.record` already use | A pasteboard carrying an image and a single space would otherwise open the editor on nothing. Reusing the existing rule rather than writing a second one matters because a capture path and a session path disagreeing about whether a buffer has text is the kind of divergence nobody notices until it produces two different answers for the same clipboard. |
| An RTFD with an embedded image | **Not** an image | The field means a standalone pasteboard image type (`.png`/`.tiff`). Without this rule every rich paste from a web page becomes an image session — the regression "image wins" was rejected for, wearing a different costume. |
| Save semantics | Writes everything the session holds: text as edited, image unchanged | `ClipboardBridge.write(text:richRTFD:imagePNG:)` already does exactly this. Save must never write *less* than it was given; silently dropping an image the user never touched is data loss, and a mixed session is what invites it. |
| Session size cap | None | The session holds whatever the clipboard had. History's 5 MB skip and upload's 16 MB refusal are genuinely different budgets (durable storage versus one transfer) and both already exist and both already say so. An 8 MB screenshot being viewable and uploadable but not recorded is already true today; this makes it visible rather than introducing it. |
| Transform applicability | A form declaration on `Transformer`, defaulting to `.text` | ~30 existing transforms need no change, and a new transform cannot accidentally claim to handle images. `TransformCoordinator.isEnabled(_:for:)` already filters per document, so the check goes where filtering already lives. |
| Form vs `applicableKinds` | Separate axes | `applicableKinds` drives detection-based *promotion* — what sorts first. Form is *applicability* — what can run at all. Conflating them would make "promoted" and "possible" one thing, and they are not. |
| History ↵ on an image row | Opens it, like every other row | The current redirect to copy-back is a workaround for the limitation this removes, and ↵ meaning "load this into the panel" becomes true for every row type. ⌘↵ still copies back, so nothing is lost — and opening is how a history image reaches upload, OCR and EXIF stripping, which is most of why you would want it. The README paragraph documenting the old rule changes in the same commit. |
| Script image support | Not here (#67) | Script-derived transforms inherit the form declaration for free. No `# pastefix: accepts = image` metadata key is added: a key a user can write that silently does nothing is worse than its absence (the repo's own lesson, from a settings value written as the wrong `defaults` type and silently ignored). |

## The Critical Invariant 13 consequence

Plan 13 established:

> clipboard text leaves the machine only through a surface that has scanned it
> in full, and "not scanned" is never "clean"

Detection and secret scanning read `working: String`. An image session has no
text, so `ContentDetector` finds nothing and `secretMatches` is empty —
correctly, because nothing was scanned. `secretScanSkipped` does not carry this
either: that flag means "over the 256 KB cap", not "unscannable in principle".

A screenshot of a terminal holding a token is an entirely ordinary thing to have
on the clipboard. So when #48 lands, image upload will send content that has
never been scanned, through a gate whose premise is that it scans.

**Decided: image upload must state plainly that images are not scanned** — its
own verdict row, not the clean one. Invariant 13 is satisfied by never claiming
clean, which is exactly what it says. OCR (#19) stays off the critical path, and
image secret scanning becomes a later feature rather than a blocker.

The requirement this puts on #48, recorded here because that is where it will be
read: **the "not scanned" state must be as loud as a finding**, not a footnote. A
quiet "no secrets found" for an image would be the false all-clear this invariant
exists to prevent, in a new outfit.

## Architecture

### PastefixAppCore

```swift
public struct ClipboardSnapshot: Sendable {
    public let plainText: String?
    public let richRTFD: Data?
    /// A standalone pasteboard image, normalised to PNG. Nil when the pasteboard
    /// had none, when its provider never materialised the promised data, or when
    /// the bytes did not decode. An image embedded in `richRTFD` is *not* this.
    public let imagePNG: Data?
    public let changeCount: Int?
}
```

`PasteDocument` exposes `origin.imagePNG` and gains one derived question — does
this session display as an image? True when an image is present and the text is
blank once trimmed, which is the rule `PendingImage.resolve:33` and
`HistoryStore.record` already apply (`trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`).
Its text state is untouched.

### PastefixCore

```swift
/// What a transform can run on. Defaults to `.text`, so every existing
/// transform is unchanged and a new one cannot claim images by omission.
public enum ContentForm: Sendable { case text, image }

public protocol Transformer {
    // …existing requirements…
    var acceptedForms: Set<ContentForm> { get }   // default: [.text]
}
```

`TransformCoordinator.isEnabled(_:for:)` gains a form check beside its existing
enabled check — the palette and sidebar then filter naturally, and show nothing
for an image session until #20 adds the first image transform.

### App target

The panel branches on the document's display form: the image view when there is
an image and no text, the editor otherwise. An image session's ⌘K palette says
no transforms apply to an image rather than rendering an empty list — an empty
palette reads as a broken panel, and this increment deliberately ships no image
transforms.

## Data flow

1. Summon reads the pasteboard. `ClipboardSnapshot` captures text, rich content
   and — new — a standalone image, normalised to PNG.
2. The session carries all three. What the panel *shows* follows the content:
   an image with blank-or-absent text renders the image; anything with real text
   renders the editor.
3. Transforms filter by form, so a text session behaves exactly as today and an
   image session offers none (in this increment).
4. Save / ⌘↵ writes back everything the session holds — text as edited, image
   unchanged.
5. ↵ on an image history row loads it into a session rather than copying it
   back. ⌘↵ still copies back.

## Error handling

| Case | Behaviour |
|---|---|
| Pasteboard advertises an image type but its provider never materialised the data | Treated as **no image**, never as an empty one. Otherwise a session claims an image it does not have and Save writes zero bytes over the user's clipboard. (`pb save/restore` in `docs/gui-automation.md` hit exactly this and had to skip unmaterialised types.) |
| Advertised as an image, does not decode | No image; fall back to the text path. With no text either, that is the honest empty state rather than an image session showing nothing. |
| Image over history's 5 MB | Viewable and uploadable, not recorded. Already today's behaviour; no new code. |
| Image over upload's 16 MB | Refused by `UploadLimits`, which already names the size and the limit. |
| Mixed session, text edited | Save writes the **edited text and the original image**. This is the rule that needs a test rather than a comment. |

## Testing

Package-level, with real tests: `ClipboardSnapshot`'s image field; the
advertised-but-unmaterialised rule; the RTFD-embedded-image exclusion; form
filtering in `TransformCoordinator`; the display-form derivation for all four
combinations of text and image presence; and Save writing everything the session
holds after a text edit.

The panel's image view is app-target and has no automated coverage by design.
**Stated plainly because it matters:** the last two defects found on Plan 13 were
both app-target and both surfaced only when someone read the spec against the
code, and a third — a Keychain read on a render path — was found by watching the
app. This increment's visible half is verified by a GUI pass using the tooling in
`docs/gui-automation.md`, not by the suite.

## Project layout delta

```
Sources/PastefixAppCore/ClipboardSnapshot.swift      # imagePNG field
Sources/PastefixAppCore/PasteDocument.swift          # display-form derivation
Sources/PastefixAppCore/TransformCoordinator.swift   # form filtering
Sources/PastefixCore/Transformer.swift               # ContentForm, acceptedForms
Pastefix/Pastefix/ClipboardBridge.swift              # read a standalone image
Pastefix/Pastefix/PanelView.swift                    # image view branch
Pastefix/Pastefix/ImageSessionView.swift             # the image view itself
Pastefix/Pastefix/AppModel.swift                     # load an image history item
Pastefix/Pastefix/HistoryOverlayView.swift           # ↵ opens image rows
README.md                                            # ↵ rule, image sessions
```
