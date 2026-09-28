---
type: spec
status: draft
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
- `Transformer` gains `func transform(_ input: TransformInput) async throws -> TransformOutput`, whose default implementation is `.text(try await apply(input))`. **No existing transform, script, JS transform or preset changes**, in code or behaviour. An image-producing transform implements `transform` directly. The plan decides how an image transform satisfies the `apply(_:) -> String` requirement (for instance, a refining protocol that supplies a throwing `apply`); what matters is that `apply` is never called for it.
- **Gating is unchanged in code.** `acceptedForms` already exists (#18), and `TransformCoordinator.isEnabled` already checks it against `displaysAsImage`, which now tracks the current entry. Both new transforms declare `[.image]`. User scripts stay text-only; #67 is out of scope.
- **A "nothing to do" result that carries a message.** Today `.unchanged` is silent. A transform can now report that it had nothing to do, with a user-facing sentence; nothing is pushed, and the message is shown in the notice banner (amber), not the error banner (red). This is how #82 says "nothing to remove" and #19 says "no text recognised".
- **The coordinator** pushes whichever entry comes back:
  - A text result is pushed as today, and detection is requested.
  - An image result **must be a real PNG** (`ImageBytes.isPNG`, #97); otherwise the transform fails with a message and nothing is pushed.
  - An identical result (same text, or same image bytes) is `.unchanged`, with no push.
- **Limits for image input.** The 1 MB text cap does not apply. An image transform is bounded by the app's pixel ceiling (`PixelLimits.maxConvertiblePixels`, 25 MP) and refused above it with the same wording upload uses; it never downscales. It declares its own timeout, about 10 s (a 20 MP decode alone is about 1 s).
- **One process-wide lane for image transforms** (`SingleSlotLane`, `static`). A CG decode cannot be cancelled, so a cancelled apply (Esc, a new summon) keeps decoding. Without a shared lane, repeated attempts stack decodes of hundreds of MB, which is the #46/#48 lesson.
- **Palette and sidebar**, in an image session, list the image transforms instead of "No transforms apply to a picture yet". That empty state stays for any context with nothing applicable.

### #82 — "Strip Image Metadata"

- Image in, image out; category **Privacy**; runs `ImageSanitizer.stripped` on the image-transform lane. It removes exactly what upload removes: GPS, EXIF, TIFF, IPTC, XMP, PNG text chunks; bakes orientation into the pixels; keeps a standard colour profile and converts any other to Display P3. There is no second implementation.
- **New pure `ImageMetadata.inspect(_:)`** (PastefixCore, beside `ImageSanitizer`) reads the image's properties with `CGImageSourceCopyPropertiesAtIndex`, no decode, and reports what is present as user-facing categories: **location** (GPS), **camera and date details** (EXIF/TIFF make, model, dates), **other metadata** (any other EXIF, TIFF, IPTC, XMP or PNG text).
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
- `SavePayload` after an image result and after undo.
- App tests: the palette in an image session lists "Strip Image Metadata"; applying it swaps the displayed image and ⌘Z restores it.
- Owner GUI pass: strip a GPS-tagged PNG, Save, paste elsewhere, and confirm the metadata is gone; ⌘Z; "nothing to remove" on a clean screenshot.

## Part 2 — #19, "Extract Text (OCR)" (Plan 21)

Built on part 1, planned and shipped after it.

- Image in, text out. The session becomes a text session holding the recognised text; ⌘Z restores the image. Save after OCR writes the text only.
- `VNRecognizeTextRequest`, `.accurate`, `usesLanguageCorrection = false`, languages detected automatically (`automaticallyDetectsLanguage`). No language picker, no mode picker: the issue's real-capture measurement found `.accurate` recalls more than twice what `.fast` does. The code lives in `PastefixAppCore` beside the existing Vision use in `ImageUploadPreparation`; Vision is a system framework, so Critical Invariant 4 holds.
- **Reading order:** observations are rebuilt into lines by bounding box (top to bottom, then left to right, merging observations whose vertical extents overlap), so a token Vision split across observations comes out whole on one line.
- **No text recognised:** the "nothing to do" result: "No text was recognised in this image." The wording is deliberately not "this image has no text": Vision can return nothing on an image that is full of text.
- **Tiling as a fallback, not always.** Recognise the whole image first. Only if that returns nothing, recognise again in 2048 px tiles with 64 px overlap, map tile coordinates back to the image, and drop observations duplicated in the overlaps. The measured failure is an *empty* result (0 lines on some synthetic layouts at `.accurate`, full results on the real capture), and duplicate removal is only paid when it is needed. *Accepted risk:* a partial result on a huge image is not retried.
- **No confusable folding in the output.** The issue recommended folding Cyrillic and other lookalike characters to ASCII, but that was to help *secret scanning* of OCR text. Applied to the output, it would corrupt genuine non-Latin text. OCR output is scanned like any other text in the editor; teaching `SecretDetector` about confusables is a separate change, out of scope.
- Bounded by the same pixel ceiling, timeout and lane as part 1.

### Testing (part 2)

- A synthetic-render recall suite: text rendered in-process (no committed fixtures) and recognised, asserting on the recovered lines, per the issue's requirement 5.
- Line reassembly from constructed observations: two observations on one line join in x order; separate lines stay separate.
- The tiled fallback: tile mapping and overlap de-duplication, on constructed observations.
- An image with no text gives the "nothing to do" result, and pushes nothing.
- Owner GUI pass: OCR a real terminal screenshot; ⌘Z back to the image; Save writes the text.

## Out of scope

- Text-to-image transforms (QR codes) and format conversion: the rest of #21. `Entry` and `TransformOutput` leave room for them.
- Image-aware user scripts (#67).
- Confusable folding in `SecretDetector`.
- Cleaning an image out of history when its stripped version is saved.
- Transforms on the image attached to a *mixed* session. Image transforms apply only when the current entry is an image.
