---
type: spec
status: draft
id: 2026-09-26-pastefix-v2-strip-image-metadata
title: Pastefix v2 — Strip Image Metadata (Plan 16)
description: A pure ImageSanitizer in PastefixCore removes GPS, EXIF, TIFF, IPTC, XMP and PNG text from an image, bakes orientation into the pixels, keeps a standard colour profile and replaces any other, and returns a SanitizedImage that only it can construct. Image upload (#48) applies it by default. Save and history stay verbatim. A user-invokable ⌘K transform is deferred, because transforms cannot yet output an image.
tags: [pastefix, macos, swift, images, privacy]
timestamp: 2026-09-26T23:30:00Z
---

# Pastefix v2 — Strip Image Metadata (Plan 16)

Source: [#20](https://github.com/bnaylor/pastefix/issues/20): "Strip EXIF/GPS/device metadata from an image before saving or uploading; on by default for uploads."

Supersedes the untracked draft that proposed a ⌘K transform. That draft claimed a transform declaring `acceptedForms: [.image]` "gets the ⌘K palette, the sidebar, enable/reorder and search for free". That is false. `Transformer.apply(_:)` returns `String`, `TransformInput` has no image field, and `PasteDocument`'s undo history is `[String]`. A transform that outputs an image needs image-output transforms and image undo, which is the editing feature Plan 15 split out.

## Why this exists: measured, not assumed

The pasteboard carries whatever the writing app puts there. The per-source measurements are on #20:

- **Photos.app** hands over full GPS: latitude, longitude, altitude, timestamp and compass bearing. It also hands over 35 EXIF keys naming the device, and a file-url to the un-stripped original.
- Chrome, Preview and Finder re-render or hand over an icon. Even so, Chrome, Finder and Photos all put a **pointer** to the un-stripped original on the clipboard beside the image.
- The session's TIFF→PNG conversion drops metadata (`ConversionStripsLocationTests`, #78). So a Photos session is clean, by an enforced accident.
- The **verbatim PNG path keeps it.** Any source that writes a geotagged PNG puts the coordinates in the session.

So an upload of `document.imagePNG` publishes GPS whenever the source wrote a geotagged PNG. This increment closes that before #48 can ship.

## Scope

**In:**
- `ImageSanitizer.stripped(_:) -> SanitizedImage?` in **`PastefixCore`**: a pure function, PNG out. `SanitizedImage`'s initialiser is file-private, so the only way to get one is a successful strip.
- `PixelLimits` (the 25 MP ceiling and overflow-safe pixel counting) moves to Core, with `ImageBytes` forwarding to it. That keeps one ceiling, not two.
- Image upload (#48) applies it by default. The plumbing is #48's; this increment supplies a tested function and its contract.

**Out:**
- **A ⌘K "Strip Metadata" transform.** Filed separately; blocked on image-output transforms.
- **Stripping on Save.** Save writes back what was copied, which is Plan 15's rule. Changing a clipboard's bytes on a plain Save is the surprise that plan avoided.
- **Stripping history.** History is local and owner-only (Invariant 12). The harm #20 names is publication.
- Format conversion (#21).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Shape | A pure function, not a transform | Transforms cannot output an image yet. The upload path needs a function, and a function is testable without a pasteboard. |
| Output format | PNG | The same canonical form the session uses. Re-encoding is what strips, so the output is never the input's bytes. |
| Orientation | **Baked into pixels**, then the tag is dropped | Naively stripping EXIF rotates photographs: a phone writes landscape sensor pixels plus Orientation 6. Measured: a 60×40 fixture tagged 6 comes out 40×60 with no tag, and a pixel that should move under a 90° clockwise rotation does move. So the rotation is applied, not merely forgotten. |
| Colour | **A standard profile is kept exactly. Any other is replaced by converting to Display P3.** | Dropping the profile shifts colours. But keeping *any* profile leaks: screenshots embed the **display's** profile, a calibrated display's profile is often named after the person or machine, and every ICC header carries the device manufacturer, model and a creation date. Measured: a colorimetrically non-standard profile is embedded as-is in the output. (Renaming a copy of sRGB is not enough to test this, because ColorSync matches it back to sRGB.) The allowlist is sRGB, Display P3, Adobe RGB 1998, Generic Gray 2.2, extended/linear sRGB, and ITU-R 2020. Conversion is visually lossless within P3; a wider custom gamut clips slightly, and that cost is accepted. Raised in review by `work`. |
| What survives | Pixel dimensions and colour profile only | Measured: the only EXIF left after encoding is `PixelXDimension`/`PixelYDimension`, which the PNG encoder synthesises. Finder's icon carries the same two keys. GPS, TIFF (Make/Model/Orientation), IPTC and EXIF dates are all gone. |
| Idempotence | Stripping twice equals stripping once | Measured on TIFF, PNG and JPEG inputs. It's a testable house rule. |
| Pixel ceiling | `PixelLimits.maxConvertiblePixels`. Over it the function **refuses**; it never downscales | Downscaling would silently change what the user chose to share. Note who hits this: `normalise` keeps a PNG verbatim *without* a pixel check, so a session can hold a 40 MP PNG that the sanitizer then refuses. An explicit, user-chosen "upload downscaled" would belong to #21. The refusal should name the figure via `megapixelLabel`. |
| Where it runs | Off the main actor, by its caller | A full decode plus encode. #48's overlay already scans in a detached task, so stripping joins that task. |
| Failure | nil, never the unstripped input, **and falling back can't compile** | #48's upload accepts a `SanitizedImage`, never `Data`, so `?? document.imagePNG` is a type error rather than something a test has to catch. This is the same shape as `UploadPayload.text` for the secret gate. Suggested in review by `work`. |
| Opt-out | **None in this increment** | #20 says "on by default", which implies an off switch. If #48 offers one, it has to be an explicit per-upload choice (like the secret gate's "send as-is"), never a Settings default that silently makes uploads verbatim. And it would need its own path to a `SanitizedImage`-free upload, which is deliberately hard to write. |
| Invariant 13 for images | The sanitizer is the gate; nil refuses | Invariant 13's scan clause is written for text. For an image upload, the equivalent is that the bytes leave only as a `SanitizedImage`. Images are **not** scanned for secrets (that's #19, OCR), and the upload surface must say so. |
| Decoder limits (named, not chosen) | 8 bits per channel; first frame only | The thumbnail decoder yields 8-bit output, so a 16-bit or HDR source loses depth and any gain map. An animated PNG uploads its first frame, and a multi-page TIFF its first page. |
| Pointers | Never resolved | Invariant 13's allowlist clause. The sanitizer takes the session's bytes and nothing on the pasteboard. |

## The pin from #78 becomes plain assertions

#78 pinned "a GPS-bearing PNG through `normalise` keeps its GPS" as a known issue. Under this design #20 **doesn't** change `normalise`, so #80 re-worded the pin to "verbatim by design". Save stays verbatim, and stripping happens on the way out. So the pin's premise is wrong. In this increment it becomes two plain assertions: `normalise` keeps a PNG verbatim, GPS included (intended, because Save must write what was copied), and `ImageSanitizer.stripped` removes the GPS. That puts the safety claim where the safety actually is.

## Testing

All package-level, using synthetic fixtures (never a real photo):
- GPS, EXIF dates, TIFF Make/Model, IPTC and XMP are removed. Each fixture is checked to really carry them first, or the test proves nothing.
- Orientation 6: dimensions swap, the tag is gone, and a corner pixel moves as a clockwise rotation predicts.
- The ICC profile name survives.
- Idempotent.
- nil over the ceiling, nil for bytes that don't decode, nil for empty input. Never `Data()`, and never the input.
- TIFF, PNG and JPEG inputs.
- Dimensions are unchanged when there's nothing to rotate, which catches a silent downscale.
- A non-standard profile comes out as Display P3. The fixture is sRGB with its red primary perturbed and its profile ID cleared.
- Alpha is kept on both paths: with a standard profile, and through the P3 redraw.
- PNG text chunks (`Software`) are dropped. The test checks the raw bytes, not just the parsed properties.

Mutations checked, each caught by the test named for it: carrying source properties across, skipping the orientation transform, a fallback returning the input, removing the ceiling, halving the max size, keeping any profile, and losing alpha in the redraw. The last one found a gap: the original alpha test used a standard profile and never reached the redraw path.

Each property gets a mutation check. Examples: skip the orientation transform, pass the source properties through, drop the colour space. Each mutation must fail a named test, and the harness must first be checked on one mutation by hand (the #78 lesson).

## Resolved while specifying

- **Photos' orientation.** It was suspected that the session's TIFF→PNG conversion drops an Orientation tag without applying it, which would have made #78 show phone portraits on their side. Measured: `NSBitmapImageRep` **applies** the tag (a 16×12 TIFF tagged 6 converts to 12×16). No defect. It is now pinned by a test on #78's branch, because this increment's sanitizer uses a different decoder (`CGImageSourceCreateThumbnailAtIndex` with the transform flag), and a future unification of the two must not silently lose the property.
