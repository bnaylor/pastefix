---
type: spec
status: part 1 implemented (Plan 20); part 2 pending (Plan 21)
id: 2026-09-28-pastefix-v2-image-transforms
title: Pastefix v2 — Image Transforms (Plans 20 and 21, #82, #19)
description: Transforms that take an image and produce an image or text. PasteDocument's undo history holds text or image entries, one cursor across both. Part 1 (Plan 20) builds that and ships "Strip Image Metadata" (#82) on ImageSanitizer; part 2 (Plan 21) ships "Extract Text (OCR)" (#19) on Vision.
tags: [pastefix, macos, swift, images, transforms, privacy, ocr]
timestamp: 2026-09-28T09:00:00Z
---

# Pastefix v2 — Image Transforms (Plans 20 and 21)

Source: [#82](https://github.com/bnaylor/pastefix/issues/82) and [#19](https://github.com/bnaylor/pastefix/issues/19). The owner's order: #82 first, then #19. Designed together, because both need the same missing piece, then planned and shipped separately.

## Why

A session can show an image (#18), but no transform can touch one. `Transformer.apply(_:)` returns `String`, `TransformInput` has no image, and `PasteDocument`'s undo history is `[String]`. Today the ⌘K palette in an image session says "No transforms apply to a picture yet".

**#82 on its own is thin**, and the design is honest about that. Upload already strips metadata (#20), and every image that came through the TIFF conversion (all Photos.app copies) is already stripped. The audience is a PNG copied *verbatim* with metadata inside, from Safari or Preview for instance, that is about to be pasted somewhere else. #82 is still the right first step because of the foundation it forces, which #19, and later the rest of #21 (format conversion, QR codes), need as well.

## Decisions (owner, 2026-09-28)

- **Approach:** one undo history whose entries are text *or* image, rather than a second image stack or a side channel.
- **OCR replaces the image.** The session becomes a text session holding the recognised text; ⌘Z brings the image back. Save after OCR writes the text only.
- The design sections below (history model, transform interface, #82, #19) were each approved in conversation.

## Part 1 — the foundation, and #82 (Plan 20)

### History model

- `PasteDocument.history` becomes `[Entry]`, `enum Entry { case text(String); case image(Data) }`. An image entry holds PNG bytes, never empty. One cursor, so ⌘Z and ⌘⇧Z walk a single order across both kinds: strip, then OCR, then ⌘Z twice gets back to the original image.
- **The first entry follows today's rule, unchanged.** An origin with an image and no real text (blank once trimmed) opens as `.image(origin image)`; everything else opens as `.text(origin text)`, mixed sessions included.
- **`displaysAsImage` becomes "the current entry is an image".** This does **not** reopen the trap recorded in AGENTS.md ("A derived display rule is a trap when what it derives from is editable"). What bit there was deriving the display from *editable text*: ⌘A+Delete flipped the view on a keystroke with no undo. Here the display follows the *form of the current entry*, which only a transform, undo or redo changes, all of which are undoable. `setWorking`, the keystroke path, is ignored while an image entry is current: there is no editor on screen, and no keystroke can create or remove an entry. The AGENTS.md entry gets a sentence saying so.
  - **`refresh`** is the one path that changes the form without an undo record. It replaces the whole document, as it does today, and `PanelView`'s `onChange(of: displaysAsImage)` already handles the preview dead end, so it does not reopen the trap either. The AGENTS.md sentence says this too.
  - **A stale editor write-back is ignored.** The TextEditor's binding calls `setWorking`, and an IME commit or end-of-editing write can land *after* ⌘Z has moved the cursor onto an image entry. "Ignored on an image entry" is what makes that harmless, so it is pinned by a `PasteDocument` test, not just stated.
  - `displaysAsImage`'s long doc comment, which explains why it must never be computed, is rewritten to explain why *this* derivation is safe, rather than left contradicting the code.
- **`pushState` compares entries, not text.** Its guard is `text != working` today; with an image entry current, pushing `.text("")` would compare `"" == ""` and be dropped silently. The guard becomes `entry != currentEntry`.
- **`isUnedited`** means: one entry, cursor at 0, **equal to the entry the init rule produced** (not `origin.plainText ?? ""`, which is false for an `.image` first entry), and no output mode armed. `isStale`, `matchesPasteboard` and `saveWouldLoseContent` inherit it; getting it wrong would switch off ⌘⇧U's re-snapshot and Save's refusal.
- **Output mode is ignored while an image entry is current.** `outputMode` is document-wide and survives undo. Without this rule: OCR, then Markdown → Rich (armed), then ⌘Z onto the image, and Save takes the rendered-Markdown branch with `working` = `""` and the image in the payload — an empty HTML/RTF written beside the PNG, which rich-aware targets prefer, so the paste comes out empty. Save does not take that branch on an image entry, and the armed badge is hidden there. Redo back onto the text entry shows it again.
- **Rich transforms require a session that opened as text.** `isEnabled` gives a `requiresRichInput` transform `origin.hasRichContent`. An image origin can carry HTML beside it (Chrome's "Copy Image" writes `public.html`), so after OCR, Rich → Plain and Rich → Markdown would light up and replace the OCR text with a rendering of the origin's HTML. They are enabled only when the first entry is text.
- **⌘Z under an open ⌘⇧U.** Undo and redo are gated on `isApplying`, not on the upload overlay, so ⌘Z can flip the form beneath an open upload overlay. That is safe: the overlay snapshots its input when it opens (text or image) and uploads that snapshot, which is also what it scanned or stripped.
- **`working`** is the current entry's text, or `""` for an image entry. That is effectively what an image session has today, so detection sees nothing, as now.
  - *Consequence, accepted:* an origin whose text is whitespace-only beside an image used to keep that whitespace in `working`, and an unedited Save wrote it back. Now the entry's text is `""`, and an unedited Save writes the image without the whitespace. `saveWouldLoseContent` does not refuse it: `ClipboardSnapshot.unreproduced(by:)` skips text that is blank once trimmed, the codebase's one "blank is no text" rule. Whitespace beside an image is not content anyone copied on purpose.
- **`imagePNG`**, the image that Save, upload and the view use:
  - For a session that **opened as text or mixed**: the origin's image, carried through text transforms exactly as today.
  - For a session that **opened as an image**: the current entry's image, and **nil on a text entry**. This is what makes OCR "replace" the image. ⌘Z restores it, and Save writes it again.
- **Byte counts** (`workingByteCount`, the 1 MB placeholder of #52) count text only. Image entries count 0.
- **`isUnedited`** keeps its meaning: one entry, cursor at 0, equal to what the origin produced, no output mode armed.
- **Memory, accepted:** each image entry keeps its PNG for undo; a 25 MP screenshot is tens of MB per entry. No cap. Sessions are short, image transforms are few, and the history is dropped when the session ends. If it proves a problem, the bound to add is "the original plus the newest image".

### Transform interface

- `TransformInput` gains `image: Data?`: the current image entry's PNG, or nil on a text entry.
- New `enum TransformOutput { case text(String); case image(Data) }`.
- `Transformer` gains `func transform(_ input: TransformInput) async throws -> TransformOutput` **as a protocol requirement**, not only an extension method: the coordinator calls through `any Transformer`, and an extension-only method dispatches statically to the default, so an image transform's own `transform` would never run. A test applies an image transformer through `any Transformer`. Adding a requirement shifts witness-table slots, the cause of Plan 14's stale-build SIGSEGV, so the plan requires a clean build. Its default implementation is `.text(try await apply(input))`. **No existing transform, script, JS transform or preset changes**, in code or behaviour. An image-producing transform implements `transform` directly. The plan decides how an image transform satisfies the `apply(_:) -> String` requirement (for instance, a refining protocol that supplies a throwing `apply`); what matters is that `apply` is never called for it.
- **Gating is unchanged in code.** `acceptedForms` already exists (#18), and `TransformCoordinator.isEnabled` already checks it against `displaysAsImage`, which now tracks the current entry. Both new transforms declare `[.image]`. User scripts stay text-only; #67 is out of scope.
- **A transform can report a sentence, as a new transient "transform note".** Today `.unchanged` is silent. A transform can now say it had nothing to do ("nothing to remove", "no text recognised"), in which case nothing is pushed, or say what it did ("Removed location and camera details."), alongside a push.
  - It is **not** `noticeMessage`. AGENTS.md defines that as a standing fact about the origin, cleared only at session boundaries, so a transform's sentence placed there would outlive the ⌘Z that makes it false.
  - The note is its own slot and **belongs to the entry it describes**: redo onto a stripped image shows "Removed location…" again, and undo to the original shows nothing. A "nothing to do" sentence has no entry, so undo or redo clears it; so do the next apply and every session boundary. It is drawn in the notice style (amber, informational), and the one banner slot's priority becomes: error, then transform note, then notice. *(Changed in the GUI pass: the spec first cleared the note on undo and redo, and since a stripped image looks identical to its original, undo and redo gave no visible feedback at all.)*
- **⌘Z and ⌘⇧Z drive undo and redo while an image is showing.** *(Found in the GUI pass: nothing bound ⌘Z to Pastefix's undo at all; only the toolbar buttons did. An image session has no editor to take ⌘Z, so it did nothing.)* In a text session ⌘Z stays the editor's typing undo; undoing transforms there by keyboard is its own issue, since typing-undo and transform-undo would compete for the key.
- **The coordinator** pushes whichever entry comes back:
  - A text result is pushed as today, and detection is requested.
  - An image result **must be a real PNG** (`ImageBytes.isPNG`, #97); otherwise the transform fails with a message and nothing is pushed.
  - An identical result (same text, or same image bytes) is `.unchanged`, with no push. The image branch comes before the 1 MB text cap, and `.unchanged` compares entries.
- **Limits for image input.** The 1 MB text cap does not apply. An image transform is bounded by the app's pixel ceiling (`PixelLimits.maxConvertiblePixels`, 25 MP) and refused above it with the same wording upload uses; it never downscales. It declares its own timeout, about 10 s (a 20 MP decode alone is about 1 s).
- **One process-wide lane for image transforms** (`SingleSlotLane`, `static`). A CG decode cannot be cancelled, so a cancelled apply (Esc, a new summon) keeps decoding. Without a shared lane, repeated attempts stack decodes of hundreds of MB, which is the #46/#48 lesson.
  - **The process-wide bound is three decodes, stated rather than hidden.** There are now three lanes of uncancellable decodes: history capture's (`TIFFConversionSlot`), upload preparation's, and this one. Opening ⌘⇧U, closing it mid-preparation, then applying Strip can run one on each, about 1 GB at 25 MP each in the worst case. They are not merged because their supersession rules differ: a newer upload overlay supersedes a waiting preparation (whose card has a `superseded` state), and an image transform displacing a waiting preparation would strand that card. Merging them is a design of its own; if it is ever done, this sentence is where to start.
- **Palette and sidebar**, in an image session, list the image transforms instead of "No transforms apply to a picture yet". That empty state stays for any context with nothing applicable.

### #82 — "Strip Image Metadata"

- Image in, image out; category **Privacy**; runs `ImageSanitizer.stripped` on the image-transform lane. It removes exactly what upload removes: GPS, EXIF, TIFF, IPTC, XMP, PNG text chunks; bakes orientation into the pixels; keeps a standard colour profile and converts any other to Display P3. There is no second implementation.
- **New pure `ImageMetadata.inspect(_:)`** (PastefixCore, beside `ImageSanitizer`) reads the image's properties with `CGImageSourceCopyPropertiesAtIndex`, no decode, and reports what is present as user-facing categories: **location** (GPS), **camera and date details** (EXIF/TIFF make, model, dates), **other metadata** (any other EXIF, TIFF, IPTC, XMP or PNG text).
  - **Structural keys don't count, by an explicit allowlist.** ImageIO fills keys into *every* image. Measured in the spec review: a bare PNG freshly written by `CGImageDestination` reports `{Exif: ColorSpace, PixelXDimension, PixelYDimension}` and `{PNG: Chromaticities, Gamma, InterlaceType, sRGBIntent}`, and a real ⌃⇧⌘4 screenshot reports `{TIFF: ResolutionUnit, XResolution, YResolution}`, `{Exif: PixelXDimension, PixelYDimension, UserComment}` and `{PNG: pHYs}`. Without an allowlist, "other metadata" is true of every image, "nothing to remove" is unreachable, and Strip run twice reports a removal both times. The allowlist: pixel dimensions, colour space, resolution/DPI and its unit, gamma, chromaticities, sRGB intent, interlace, `pHYs`, orientation, colour profile.
  - **A screenshot's `Exif UserComment` of exactly `Screenshot`** (what macOS writes) does not count; any other `UserComment` does, because a comment can hold arbitrary text.
  - Pinned by tests that `inspect(stripped(x))` reports nothing, for `x` = a GPS fixture and a rendered screenshot-shaped PNG.
  - **Something present:** strip, push the stripped image, and show a notice naming what went, e.g. "Removed location and camera details."
  - **Nothing present:** the "nothing to do" result: "This image has no location or camera details to remove." Nothing is pushed.
  - Orientation and colour-profile normalisation are not privacy and do not count as "present" on their own.
- **Over 25 MP:** refused with a message; never downscaled.
- **Save** writes the stripped PNG. **⌘Z** restores the original.
- **History is not cleaned.** The original was captured into history when it was copied, metadata included, and stays until removed (⌘⌫ in the history overlay). The stripped version is recorded on Save. History never leaves the machine; the notice does not mention it, and the README does.

### Testing (part 1)

- `PasteDocument`: the first-entry rule for text, image and mixed origins; push/undo/redo across forms; `displaysAsImage` follows the current entry; `setWorking` ignored on an image entry; `imagePNG` for sessions that opened as text/mixed versus image, including nil after a text result; byte counts; `isUnedited`.
- The coordinator: default `transform` wraps `apply` (every existing transform unchanged, pinned by the existing suites); image result pushed; a non-PNG image result refused; identical image unchanged; "nothing to do" pushes nothing and carries its message; the pixel ceiling.
- `ImageMetadata.inspect`: each category detected from real fixtures (the GPS-tagged fixtures `ConversionStripsLocationTests` already builds), and a clean image reports nothing.
- `SavePayload` after an image result and after undo; Save on an image entry ignores an armed output mode.
- `pushState` of `.text("")` onto an image entry is pushed, not dropped; `setWorking` on an image entry (a stale write-back) changes nothing; `isUnedited` for an image-first document; rich transforms disabled after OCR of an image origin that carried HTML.
- The transform note: set by an apply, cleared by the next apply, undo, redo and session boundary; priority against error and notice.
- An image transformer applied through `any Transformer` runs its own `transform`.
- `ImageMetadata.inspect` of `stripped(x)` reports nothing; a screenshot's `UserComment` of `Screenshot` does not count, any other value does.
- App tests: the palette in an image session lists "Strip Image Metadata"; applying it swaps the displayed image and ⌘Z restores it.
- Owner GUI pass: strip a GPS-tagged PNG, Save, paste elsewhere, and confirm the metadata is gone; ⌘Z; "nothing to remove" on a clean screenshot.

## Part 2 — #19, "Extract Text (OCR)" (Plan 21)

Built on part 1, planned and shipped after it.

- Image in, text out. The session becomes a text session holding the recognised text; ⌘Z restores the image. Save after OCR writes the text only.
- `VNRecognizeTextRequest`, `.accurate`, `usesLanguageCorrection = false`, languages detected automatically (`automaticallyDetectsLanguage`). No language picker, no mode picker: the issue's real-capture measurement found `.accurate` recalls more than twice what `.fast` does. The code lives in `PastefixAppCore` beside the existing Vision use in `ImageUploadPreparation`; Vision is a system framework, so Critical Invariant 4 holds.
- **Reading order:** observations are rebuilt into lines by bounding box (top to bottom, then left to right, merging observations whose vertical extents overlap), so a token Vision split across observations comes out whole on one line.
- **No text recognised:** the "nothing to do" result: "No text was recognised in this image." The wording is deliberately not "this image has no text": Vision can return nothing on an image that is full of text.
- **Tiling depends on size.** The measurements are the owner's, in comments on #19 (2026-09-27), and they point both ways: always-tile lost recall on the real capture's upscale (6/8 tiled against 7/8 whole), while a synthetic two-column 5K render at `.accurate` returned a *partial* result untiled (127 lines, 0/20 tokens) and 13/20 tiled. So:
  - **Longest side over 4096 px:** recognise both whole and in 2048 px tiles with 64 px overlap, and keep whichever recovers more characters. The measured worst case for either was 0.65 s.
  - **Otherwise:** whole only, with the tiled pass as a fallback if it returns nothing.
  - The tiled pass maps tile coordinates back to the image and drops observations duplicated in the overlaps.
- **No confusable folding in the output.** The issue recommended folding Cyrillic and other lookalike characters to ASCII, but that was to help *secret scanning* of OCR text. Applied to the output, it would corrupt genuine non-Latin text. OCR output is scanned like any other text in the editor. The only miss in the real capture was a homoglyph secret, so teaching `SecretDetector` to fold confusables in its *scan input* is filed as its own issue (#102) rather than left as a footnote.
- Bounded by the same pixel ceiling, timeout and lane as part 1.

### Testing (part 2)

- A synthetic-render recall suite: text rendered in-process (no committed fixtures) and recognised, asserting on the recovered lines, per the issue's requirement 5.
- Line reassembly from constructed observations: two observations on one line join in x order; separate lines stay separate.
- The tiling rule: the over-4096 px dual pass keeps the result with more characters; the fallback runs only on an empty result; tile mapping and overlap de-duplication, on constructed observations.
- A zero-line result **below** 4096 px triggers the tiled pass: the owner's measured 4095×1200 silent-empty case falls just under the dual-pass threshold, so the fallback is what catches it.
- An image with no text gives the "nothing to do" result, and pushes nothing.
- Owner GUI pass: OCR a real terminal screenshot; ⌘Z back to the image; Save writes the text.

## Out of scope

- Text-to-image transforms (QR codes) and format conversion: the rest of #21. `Entry` and `TransformOutput` leave room for them.
- Image-aware user scripts (#67).
- Confusable folding in `SecretDetector`.
- Cleaning an image out of history when its stripped version is saved.
- Transforms on the image attached to a *mixed* session. Image transforms apply only when the current entry is an image.
