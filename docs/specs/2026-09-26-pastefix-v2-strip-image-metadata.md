---
type: spec
status: draft
id: 2026-09-26-pastefix-v2-strip-image-metadata
title: Pastefix v2 — Strip Image Metadata (Plan 16)
description: A pure ImageSanitizer removes GPS, EXIF, TIFF, IPTC and XMP from an image, bakes orientation into the pixels and keeps the colour profile. Image upload (#48) applies it by default. Save and history stay verbatim. A user-invokable ⌘K transform is deferred, because transforms cannot yet output an image.
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
- `ImageSanitizer.stripped(_:) -> Data?` in `PastefixAppCore`: a pure function, PNG out.
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
| Colour | **ICC profile kept** | Stripping the profile shifts colours, which is a visible corruption and gains nothing for privacy. Measured: Display P3 in, Display P3 out. |
| What survives | Pixel dimensions and colour profile only | Measured: the only EXIF left after encoding is `PixelXDimension`/`PixelYDimension`, which the PNG encoder synthesises. Finder's icon carries the same two keys. GPS, TIFF (Make/Model/Orientation), IPTC and EXIF dates are all gone. |
| Idempotence | Stripping twice equals stripping once | Measured on TIFF, PNG and JPEG inputs. It's a testable house rule. |
| Pixel ceiling | `ImageBytes.maxConvertiblePixels`, over which it returns nil | This is a full decode. It is the same work the ceiling bounds everywhere else, so it gets the same ceiling. |
| Where it runs | Off the main actor, by its caller | A full decode plus encode. #48's overlay already scans in a detached task, so stripping joins that task. |
| Failure | nil, never the unstripped input | The caller must refuse to upload rather than fall back to the original bytes. A strip that silently returns its input is the false all-clear Invariant 13 forbids. |
| Pointers | Never resolved | Invariant 13's allowlist clause. The sanitizer takes the session's bytes and nothing on the pasteboard. |

## The `withKnownIssue("#20")` pin from #78 must change

#78 pinned "a GPS-bearing PNG through `normalise` keeps its GPS" as a known issue that #20 would fix. **Under this design #20 does not change `normalise`.** Save stays verbatim, and stripping happens on the way out. So the pin's premise is wrong. In this increment it becomes two plain assertions: `normalise` keeps a PNG verbatim, GPS included (intended, because Save must write what was copied), and `ImageSanitizer.stripped` removes the GPS. That puts the safety claim where the safety actually is.

## Testing

All package-level, using synthetic fixtures (never a real photo):
- GPS, EXIF dates, TIFF Make/Model, IPTC and XMP are removed. Each fixture is checked to really carry them first, or the test proves nothing.
- Orientation 6: dimensions swap, the tag is gone, and a corner pixel moves as a clockwise rotation predicts.
- The ICC profile name survives.
- Idempotent.
- nil over the ceiling, nil for bytes that don't decode, nil for empty input. Never `Data()`, and never the input.
- TIFF, PNG and JPEG inputs.

Each property gets a mutation check. Examples: skip the orientation transform, pass the source properties through, drop the colour space. Each mutation must fail a named test, and the harness must first be checked on one mutation by hand (the #78 lesson).

## Resolved while specifying

- **Photos' orientation.** It was suspected that the session's TIFF→PNG conversion drops an Orientation tag without applying it, which would have made #78 show phone portraits on their side. Measured: `NSBitmapImageRep` **applies** the tag (a 16×12 TIFF tagged 6 converts to 12×16). No defect. It is now pinned by a test on #78's branch, because this increment's sanitizer uses a different decoder (`CGImageSourceCreateThumbnailAtIndex` with the transform flag), and a future unification of the two must not silently lose the property.
