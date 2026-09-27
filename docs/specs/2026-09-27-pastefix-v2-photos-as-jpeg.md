---
type: spec
status: draft
id: 2026-09-27-pastefix-v2-photos-as-jpeg
title: Pastefix v2 — Upload photos as JPEG (Plan 19, #21)
description: Image upload sends a photograph as JPEG (quality 0.85) and anything else as PNG, decided by measured compressibility rather than by guessing at content. Fixes the refusal of camera-sized photos, whose PNG exceeds the 16 MB upload cap.
tags: [pastefix, macos, swift, images, upload]
timestamp: 2026-09-27T11:00:00Z
---

# Pastefix v2 — Upload photos as JPEG (Plan 19)

Source: [#21](https://github.com/bnaylor/pastefix/issues/21), narrowed to "upload photos as JPEG". The rest of #21 (format conversion as a transform, compression controls, QR codes) stays open.

## Why

Image upload (#48) sends a stripped PNG. The 16 MB upload cap, not the 25 MP pixel ceiling, is what refuses photographs. A real 8.3 MP aerial photo is **10.1 MB as PNG and 1.6 MB as JPEG**. A camera-sized photo's PNG exceeds 16 MB, so it's refused today, which defeats "images are the main point of Zipline upload".

The owner's decisions (2026-09-27): **photos go up as JPEG**. Quality and transparency were left to this spec: **0.85**, and **anything with transparency stays PNG**.

## The decision: measured compressibility, not a content guess

By upload time every session image is PNG, so the source format is gone. Classifying "photo vs screenshot" from pixels is a heuristic that fails silently. What *is* measurable is how each format compresses the same pixels. Measured (JPEG at 0.85, both encoded to files):

| Image | PNG | JPEG | JPEG ÷ PNG |
|---|---|---|---|
| Real aerial photograph, 3840×2160 | 10.10 MB | 1.64 MB | **0.16** |
| Real photographs (macOS account pictures), 512×512 | 0.45–0.64 MB | 0.07–0.14 MB | **0.15–0.22** |
| Terminal screenshot, 3024×1964 | 0.83 MB | 1.01 MB | **1.21** |
| Flat UI screenshot, 3024×1964 | 0.19 MB | 0.27 MB | **1.41** |
| UI window over a photographic wallpaper, 3840×2160 | 5.89 MB | 1.36 MB | **0.23** |

**Rule: send JPEG when the image has no transparency and its JPEG is at most half the size of its PNG. Otherwise send PNG.** The gap between photos (≤ 0.22) and screenshots (≥ 1.21) is wide, so a threshold of 0.5 isn't sitting on a boundary.

**Named cost:** a screenshot of a desktop with a photographic wallpaper (0.23) goes up as JPEG. At 0.85 its text stays readable but picks up faint ringing around glyphs. That's accepted, because the alternative is a content heuristic that fails without saying so.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Format rule | JPEG if there's no alpha and JPEG ≤ 0.5 × PNG, else PNG | Above |
| JPEG quality | 0.85 | The usual default. Photos stay visually lossless at a fifth of the PNG's size |
| Transparency | Always PNG | JPEG has no alpha. Flattening onto a colour changes what the user sees |
| Where it runs | `ImageSanitizer` (Core), after the strip | It already decodes, orients, normalises the profile and encodes. `SanitizedImage` gains its format and extension |
| Encoding | Through the leak-safe file path (`PNGEncoder`, generalised) | ImageIO leaks in-memory PNG encodes (#87). JPEG gets measured for the same leak, and goes through a file regardless |
| Metadata | None, in either format | The JPEG encoder is given no properties. Tests assert no GPS, EXIF date, TIFF make or IPTC in the JPEG output, as for PNG |
| Upload | `ZiplineUpload(image:)` takes its extension and content type from `SanitizedImage` (`jpg` / `image/jpeg`) | Zipline serves by type |
| The card says what it sent | "Sent as JPEG (1.6 MB — the PNG would be 10.1 MB)" | A format change the user can't see would be a second silent transformation |
| Cost | Both encodes run during preparation | Measured before accepting. If it's material at the ceiling, decide on a downscaled sample instead |
| Byte cap | Applied to whichever format is sent | A photo whose JPEG still exceeds 16 MB is refused, naming the JPEG size |

## Testing

Package-level, with synthetic fixtures (noise for photo texture, rendered text for screenshots):
- A photo-like image with no alpha gives JPEG. A screenshot-like image gives PNG. Anything with alpha gives PNG.
- The JPEG output has no metadata, same assertions as the PNG path.
- The JPEG output keeps orientation (baked) and Display P3.
- The byte cap applies to the chosen format.
- The multipart part is `image/jpeg` with a `.jpg` filename.
- The threshold is mutation-checked: making every image JPEG, or never JPEG, fails named tests.

Live, against `khet`: a photo uploads as `image/jpeg`, and the served bytes equal the sent bytes.
