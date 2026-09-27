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

**What the ratio can't do (measured in review, 2026-09-27):** a full-screen ⌘⇧3 capture with the wallpaper showing (3456×2234) measured **0.28**, right beside real photos. The wallpaper's texture is what makes the PNG big. No threshold separates "photo" from "full-screen screenshot with wallpaper". Window captures (whose shadow is real alpha) and region captures of text stay PNG.

**The owner's decision:** photo-like images go JPEG, **with a one-click escape.**

## The rule

1. **Transparency means a non-opaque pixel, not an alpha channel.** `screencapture` output, and many TIFF→PNG pasteboard conversions, carry an alpha channel with every pixel at 255. Checking the channel would silently turn the feature off for them. The pixels are scanned (min alpha).
2. Any non-opaque pixel → **PNG**. Over the cap → refused, as today.
3. Opaque, and the PNG is **over** the 16 MB cap → **JPEG** if it fits, **whatever the ratio**. A refusal is worse than a lossy image. If even the JPEG doesn't fit, it's refused, naming the JPEG's size.
4. Opaque, the PNG fits, and JPEG ≤ 0.5 × PNG → **JPEG, with "Send as PNG instead"** on the card.
5. Otherwise → **PNG**.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Format rule | Above; the choice is a pure function, `ImageFormatChoice` | Above |
| JPEG quality | 0.85 | The usual default. Photos stay visually lossless at a fifth of the PNG's size |
| Transparency | Any non-opaque *pixel* means PNG | JPEG has no alpha, and flattening changes what the user sees. The test is on pixels, not on the channel's presence (see the rule) |
| Where it runs | `ImageSanitizer` (Core), after the strip | It already decodes, orients, normalises the profile and encodes. `SanitizedImage` gains its format and extension |
| Encoding | A bare `CGImage` via `CGImageDestinationAddImage`, **never** from a source (`AddImageFromSource` could carry MakerNote, gain maps or auxiliary data), through the file path | Measured: JPEG encoding does **not** leak (+0 MB over six in-memory encodes; #87 is PNG-specific). The file path is kept for consistency |
| Metadata | An **allowlist of JPEG segments**, not a denylist of properties | The test walks the markers and allows only SOI, APP0 JFIF, APP2 ICC_PROFILE (bytes equal to canonical Display P3), DQT, SOF0/SOF2, DHT, DRI and SOS…EOI, **with nothing after EOI**. Anything else fails, including APP1 (EXIF and XMP), APP13 (IPTC), COM, APP2 MPF (gain maps, depth), APP14 and embedded thumbnails. That's `release.sh`'s allowlist lesson again |
| Upload | `ZiplineUpload(image:)` takes its extension and content type from `SanitizedImage` (`jpg` / `image/jpeg`) | Zipline serves by type |
| The card says what it sent | "Sending as JPEG (1.6 MB; as PNG it would be 10.1 MB)", plus **Send as PNG instead** when the PNG fits. When JPEG was forced by the cap, the card says so, with no escape | A format change the user can't see would be a second silent transformation. The escape is the owner's decision |
| Cost | Both encodes, always; no sampling | Measured: JPEG takes 0.07 s at 24 MP against the PNG's 0.83 s, about +8%. Sampling isn't needed. It would also bias the ratio from both sides: downscaling averages away the sensor noise that makes a photo's PNG big, and anti-aliases the hard text edges that keep a screenshot's PNG small |
| Byte cap | Applied to whichever format is sent | A photo whose JPEG still exceeds 16 MB is refused, naming the JPEG size |

## Testing

Package-level fixtures. **Blurred** noise stands in for photo texture: measured at 0.18–0.22, like real photos. *Uniform* noise measures 0.38, near the threshold, so it would only pass by luck. Rendered text stands in for screenshots, and there's one **screenshot-over-photographic-wallpaper** fixture that pins the owner's choice (JPEG, with the escape offered).
- A photo-like opaque image gives JPEG with the escape. A screenshot-like image gives PNG. **An RGBA image with every alpha at 255 and photo texture gives JPEG; one pixel at 254 gives PNG.** A PNG over the cap whose JPEG fits gives JPEG, whatever the ratio.
- The JPEG output has no metadata, same assertions as the PNG path.
- The JPEG output keeps orientation (baked) and Display P3.
- The byte cap applies to the chosen format.
- The multipart part is `image/jpeg` with a `.jpg` filename.
- The threshold is mutation-checked: making every image JPEG, or never JPEG, fails named tests.

Live, against `khet`: a photo uploads as `image/jpeg`, and the served bytes equal the sent bytes.
