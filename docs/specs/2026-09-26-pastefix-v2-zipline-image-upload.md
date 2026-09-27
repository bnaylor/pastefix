---
type: spec
status: draft
id: 2026-09-26-pastefix-v2-zipline-image-upload
title: Pastefix v2 — Zipline Image Upload (Plan 17)
description: ⌘⇧U on an image session strips its metadata, uploads it to Zipline as image/png, and replaces the clipboard with the short URL. Every image upload says plainly that images are not checked for secrets; an image detected to contain text says it louder.
tags: [pastefix, macos, swift, images, upload, privacy]
timestamp: 2026-09-26T23:59:00Z
---

# Pastefix v2 — Zipline Image Upload (Plan 17)

Source: [#48](https://github.com/bnaylor/pastefix/issues/48), split out of #14. The owner's framing: *images are the main point of Zipline upload.* Closes #48, and closes #20 because this is the path that applies the strip by default.

Stacked on #83 (#20's `ImageSanitizer`), which is stacked on #80 (#78: Photos.app copies become image sessions).

## Two decisions that changed from the draft

1. **The bytes that go up are a `SanitizedImage`, not `document.imagePNG` verbatim.** The draft argued for verbatim because Plan 15 kept PNG bytes unmodified. That rule is right for *Save*, which writes back what was copied. It is wrong for *publication*: a geotagged PNG would carry its coordinates into a public link (measured; see #20). `ZiplineUpload` takes a `SanitizedImage`, whose only initialiser is a successful strip, so an unstripped upload doesn't compile.
2. **No OCR, and no secret scanning of images.** The owner decided image secret scanning is a later feature (#19). An earlier review round had drifted toward putting OCR detection here. That is reversed. The measured OCR requirements stay on #19 and bind whichever increment implements scanning.

## Scope

**In:**
- ⌘⇧U on a session whose `displaysAsImage` is true uploads the image.
- Stripped via `ImageSanitizer` off the main actor, sent as `image/png` with a `.png` filename, and the short URL is written to the clipboard exactly as for text.
- A verdict row saying images are not checked for secrets, always present.
- A line saying the location and camera details were removed.
- Expiry and burn-after-reading, unchanged.

**Out:**
- OCR and secret scanning of images (#19).
- Uploading the image of a **mixed** session. A session that displays the editor uploads its **text**, as today. Image upload follows the displayed form, the same rule Plan 15 uses for everything else. **Evidence this matches what users mean:** the measured Photos.app type list carries no plain text, so a Photos copy is an image session. Chrome's "Copy Image" is the open case: if it also writes `public.utf8-plain-text` (for instance the image URL), a Chrome copy opens as a text session and ⌘⇧U would upload that string. Checked before the plan is finalised.
- Format choice (#21). A user-chosen "upload downscaled" (#21).
- An opt-out from stripping. See Decisions.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| What goes up | `ImageSanitizer.stripped(document.imagePNG)`, carried as `SanitizedImage` | See above. `ZiplineUpload` gains `init(image: SanitizedImage, expiry:burnOnRead:)`, and its body becomes `.text(String)` or `.image(SanitizedImage)`. |
| Sanitizer returns nil | **Refuse, and name why** | Over the ceiling: "31 MP; limit 25 MP" via `megapixelLabel`. Undecodable: "This image couldn't be prepared for upload". Never falls back to the original bytes, and the type makes a fallback uncompilable. |
| When the strip runs | Started from `onAppear` behind a started flag, **never from `init`**. It runs off-main, and Upload stays disabled until it resolves | The overlay's `init` runs on every `PanelView` re-render (the Keychain prompt-loop lesson in its comments). |
| **Repeat ⌘⇧U must not stack decodes** | One preparation per session: the result (or in-flight task) is cached on `AppModel`, keyed by session generation, and a rebuilt overlay reuses it. Preparations across sessions go through a process-wide single-slot lane (one running, at most one waiting; a superseded waiter never starts), the shape of `TIFFConversionSlot` | `PanelView` rebuilds the overlay with a new generation on every repeat ⌘⇧U, and a CG decode can't be cancelled. Unguarded, hammering ⌘⇧U on a 24 MP session runs N × ~330 MB decodes at once. That's the #46 lesson again: serialising the work doesn't bound the resource, and a per-instance lane is not a lane. |
| Admission cap | `UploadLimits.maxPayloadBytes` (16 MB) applied to the **stripped** bytes, after the strip | Those are the bytes that leave. The strip must run first because it can shrink the image (a 16-bit source redrawn at 8 bits), so a too-big input is fully decoded before it is refused. That is unavoidable and accepted. |
| **The byte cap, not the pixel ceiling, is what refuses photos** | Refusal names bytes and points at #21: *"22.6 MB after preparing; the limit is 16 MB. Uploading as JPEG (#21) would fit."* | **Measured** by `work` on Apple's Sonoma render, resized, through the branch's sanitizer: 12 MP → 12.5 MB PNG (0.53 s, 168 MB RSS); 20 MP → 22.6 MB (0.91 s); 24 MP → 26.5 MB (1.05 s, 326 MB). A smooth render compresses better than a real photo with sensor noise, so the cap binds earlier for real photos, estimated around 8 MP (unmeasured). So **camera-sized images between roughly 8 and 25 MP pass the pixel ceiling and are refused by the byte cap.** Photos.app copies are unaffected, since Photos hands over a reduced rendition (the 768×1024 we measured), and screenshots mostly fit because text compresses. The real fix for full-size photos is lossy output (#21), not a bigger cap. |
| Content type / filename | `image/png`; `paste.png` | Zipline serves and previews by type. `text/plain` would make it download instead. |
| Extension control | **Hidden** for an image | It exists for syntax highlighting. An editable extension on an image invites uploading a PNG as `.txt`. |
| Redact-or-send | **Absent**, not greyed | There is nothing to redact, and an inapplicable control implies a capability. |
| Secrets verdict | **Always**: "Images are not checked for secrets." Its own row, as prominent as a finding | Invariant 13: "not scanned" is never "clean". |
| Return key | **No image upload has a default send action.** Return never uploads an unscanned image. With text detected, Cancel becomes the default | The text path earns Return-to-Upload by having scanned. An unscanned image mustn't get the same affordance, or users learn that Return means it looked fine. It's the "never a quieter verdict" rule applied to the keyboard. Proposed in review by `work`. **Flagged for the owner:** the alternative (Upload as the default when no text is detected) was the original proposal and is less friction. |
| Escalation when text is detected | Vision `VNDetectTextRectanglesRequest` (region detection, not OCR). If regions are found, the verdict adds "This image contains text" and the send button reads "Upload without checking". Detection failure counts as text found | A photo of a cat shouldn't get the same alarm as a terminal screenshot, or users learn to click past it before the case where it counts. |
| …but never a quieter verdict | No "no text found" message, ever. With nothing detected, the not-checked row stays and the wording is plain | **Measured:** a single line `password=…` at 11 px produced **zero** regions. It is detected from 16 px up, and a Retina 11 pt screenshot is 22 px. So a non-Retina display, a small UI font or a scaled-down crop slips under the detector. It may escalate; it must never reassure. |
| Stripping made visible | "Location and camera details removed." | A strip the user cannot see is a second thing the upload does silently, and this surface's design is about not doing that. |
| Opt-out | **None** | An off switch that ships as a setting silently makes every upload verbatim. A per-upload "keep metadata" could come later, but it needs a deliberate `SanitizedImage`-free path that this design makes hard on purpose. |
| History | The short URL is captured as an ordinary item | No new behaviour. |
| The clipboard after success | The URL **replaces the image** on the clipboard, and the done state says so ("The image is no longer on your clipboard.") | Intended, but new: the text path never destroyed its source. |
| Overlay structure | A separate image card (`preparing` / `ready(SanitizedImage, hasText)` / `refused(reason)`) sharing only configure, uploading, done, failed and the action row with the text card | The text card's state is text-shaped: its `source: String` snapshot, `ScanState`, redaction and payload byte count. Threading optionals through it would be worse than a sibling. The image snapshot (`imagePNG`) is captured at open, like the text one. The extension seed and its late re-seed on `detectedKinds` must not run for an image. The card holds focus, so no keystroke reaches the disabled editor. Its rows join the overlay's computed height arithmetic, and the GUI pass runs at the panel's minimum height, where layout has broken before. |
| Pointers | Never resolved | Invariant 13's allowlist. The bytes come from the session, never from the pasteboard's file-url, `src` or source-url. |

## Data flow

1. ⌘⇧U. If the session `displaysAsImage`, the overlay takes `document.imagePNG`. Otherwise it's the existing text path, unchanged.
2. A detached task runs `ImageSanitizer.stripped`, then text-region detection on the stripped image.
3. The overlay shows: the not-checked row (escalated if text was found); the stripped size against the 16 MB cap; "location and camera details removed"; expiry and burn.
4. Upload sends a `ZiplineUpload(image:)`: multipart with `image/png`, `paste.png`, and the stripped bytes. It goes through the same client, redirect policy, response cap and error mapping as text.
5. On success, the short URL goes to the clipboard, the same as text.

## Error handling

Inherited entirely from Plan 13's client. Additions:
- **Sanitizer nil:** refused with the reason, and Upload stays disabled.
- **Stripped bytes over 16 MB:** refused, naming the size and the limit.
- **Session image missing:** a session that displays as an image but whose image is nil doesn't reach this path, because it is not `displaysAsImage`. Stated so the case isn't re-litigated.

## Testing

**Package, Core:**
- `ZiplineUpload(image:)` has extension `png`, and **cannot take an extension override** (the initialiser has no such parameter), so the hidden control is absent from the type, not just from the view.
- The multipart body carries `Content-Type: image/png` and the stripped bytes exactly.
- The text path's body is unchanged. Pinned, because the builder now branches.
- Text-path tests unchanged.

**Package, AppCore:**
- The text-presence function reports regions for a rendered terminal and none for a gradient.
- Failure maps to "text present".
- The 11 px miss is pinned as a *documented* limitation, so the reason the verdict never reassures is itself tested.

**App target** (no test host, #68): a GUI pass by `work`, on a synthetic geotagged image session. Confirm the verdict and removal lines, the escalation for a text-bearing image, and Cancel as the default. Then upload to a real Zipline if one is configured, and confirm the served image has no GPS.
