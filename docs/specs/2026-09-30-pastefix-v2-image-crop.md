# Image crop, and the region selection image edits build on

**Status:** approved design, 2026-09-30, revised after the `work` session's review (read against main, with #25/#26 hardware experience). It's the first of the image edits the owner wants: crop, then
redact/blur a region, resize/scale, rotate/flip, and annotate. Owner decisions are marked **(owner)**.

## Goal

Drag a rectangle on an image in the panel, choose **Crop to Selection**, and the image becomes that
rectangle, as one undoable step. This puts image mutation in play and builds the one piece the next
region tool (redact/blur) needs: a selection on the image.

## Decisions

1. **Select on the image, then transform (owner).** Crop isn't a mode. You drag a rectangle on the image
   at any time, and region-aware transforms act on it, just as text transforms act on a text selection
   since #25. The palette and sidebar show the same **Applies to selection** hint.
2. **Freeform rectangle.** It has corner and edge handles, dragging inside moves it, and it's clamped to
   the image. No aspect-ratio presets and no snapping for now.
3. **Clearing the selection:** Esc clears it, as does a click on the image outside it. A new drag
   replaces it. Esc works in this order: an open overlay or the preview closes first, then the
   region clears, then the panel cancels. It's handled in `PanelView.escape()`, not by a key
   handler on the image view (see Gestures). The Cancel button shares that handler, so with a region
   up it clears the region too. That's accepted, because clearing first is what Esc means everywhere
   else.
4. **Readout:** while a region exists, the footer reads `W×H · size · Selection w×h at (x, y)` in real
   image pixels, not the scaled display.
5. **Crop to Selection is always listed in an image session** (in the Images category), so it can be
   found. Like every image transform, it isn't listed in a text session, including a mixed image+text
   session, which opens as text. With no region,
   applying it is `.nothingToDo("Drag on the image to choose what to keep, then choose Crop to
   Selection.")`.
6. **The result** is a new image entry with the note "Cropped to w×h.", one undo step. ⌘Z restores the
   original image *and* the region; ⌘⇧Z re-crops. After a crop the selection is clear. The same holds
   for **any** transform applied in an image session with a region up, such as Strip Image Metadata:
   ⌘Z restores the region. This is the image form of #25's recheck fix.
7. **Metadata, colour, Save:**
   - Crop re-encodes through `PNGEncoder`, so image metadata is dropped. That's consistent with Strip
     Image Metadata, and a privacy plus.
   - The colour profile is **kept**. Crop decodes with orientation applied but does no profile
     normalisation (that's the sanitizer's job for uploads), so cropping never shifts colours.
   - Save writes the cropped PNG and never the origin's rich representation (`SavePayload` writes
     `richRTFD: nil`). This must stay: a Chrome "Copy Image" origin carries HTML pointing at the
     *uncropped* original, and "restore the rich representation on Save" would ship it next to the
     crop (Invariant 13).
8. **Whole-image transforms ignore a region:** Strip Image Metadata and Extract Text. (Extract Text reading
   only the region is a natural follow-up; it's out of scope here.)
9. **An image-edit pane is not built here.** The region lives in the image view, not in a tool, so a later
   pane or tool strip (most likely for annotate) can reuse it.

## Design

### Coordinates: `ImageRegion` (PastefixCore)

- A rectangle in **oriented image pixels**, origin top-left: `x, y, width, height` as `Int`. "Oriented"
  means with the EXIF orientation applied, which is how the image view draws it
  (`kCGImageSourceCreateThumbnailWithTransform`). For a 90°-rotated photo, the header's width and
  height are swapped relative to what you see. The region, the footer readout and the crop all use the
  oriented size.
- Pure helpers, all unit-tested:
  - `ImageRegion.from(viewRect:, imageFrame:, pixelSize:)` converts a rectangle in view points to image
    pixels. `imageFrame` is the fitted image's rect in the view, and the result is clamped to the image
    and rounded outward to whole pixels.
  - `ImageRegion.viewRect(imageFrame:, pixelSize:)` is the inverse, for drawing the selection.
  - `clamped(to pixelSize:)`, and `isEmpty` for a width or height under 1.
- The image's oriented pixel size comes from its header, with width and height swapped for orientations
  5–8. A shared helper computes it, used by the view's footer and by the coordinator. The footer shows
  raw header dimensions today, so it moves to this helper, or the readout and the region would
  disagree on a rotated image.
- Mapping always uses the header's pixel size, never the displayed `NSImage`'s. The displayed bitmap is
  downsampled to at most 2048 px, so a 6000 px screenshot would otherwise crop at a third of the scale.
- Oriented inputs are rare: TIFF→PNG conversion bakes orientation (`ImageBytes`). Only a PNG accepted
  as-is with an eXIf orientation reaches crop unbaked, so that's the shape of the test fixture.

### One scope type for both kinds of selection

`TransformScope` (#25) becomes an enum:

```swift
public enum TransformScope: Sendable, Equatable {
    case text(TextScope)      // #25's type, renamed from TransformScope: UTF-16 range + expected text
    case image(ImageRegion, revision: Int)
}
```

- `TextScope` keeps #25's API: `make(selected:in:)`, `selected(in:)`, `rankingKinds`.
- Every #25 call site moves to `.text(…)`, a mechanical change covered by #25's existing tests.
- `currentScope` returns `.image` only while the *current* entry is an image (`displaysAsImage`, not
  `openedAsImage`). After Extract Text the text scope applies; a leftover region never produces an
  image scope over a text entry.
- An image scope carries the `detectionRevision` of the image entry it was drawn on. At apply time the
  coordinator refuses it if the revision moved (undo, redo or refresh replaced the image), with
  "The image changed after you selected a region. Select it again.", or if it no longer fits the
  image's oriented size.

### Transforms

- `TransformInput` gains `region: ImageRegion?`, which is nil unless an image scope applies.
- New protocol `RegionImageTransformer: ImageTransformer`, with the requirement
  `transformImage(_ png: Data, region: ImageRegion?) throws -> TransformOutput`. Its `transform(_:)`
  passes `input.region` through on the image lane, exactly as `ImageTransformer` runs `transformImage(_:)`.
  Plain `ImageTransformer`s ignore the region.
- **`CropToSelection`** (`builtin.crop`, category Images, order 113):
  1. Region nil → `.nothingToDo(…)` (decision 5).
  2. Otherwise, decode at full size with orientation applied (`CGImageSourceCreateThumbnailAtIndex` with
     `WithTransform` and the full-size maximum; no profile conversion), then `CGImage.cropping(to:)`,
     then `PNGEncoder.encode`. `cropping(to:)` returns a view on the decoded image's storage, so peak
     memory is the full decode until the encode finishes. It runs on the image lane, whose bound
     covers this at up to 25 MP (about 1 s).
  3. Return `.image(png, note: "Cropped to w×h.")`.
  4. A region that is the whole image is `.nothingToDo("The selection is the whole image.")`.
- `TransformCoordinator.canScope` also covers the image case: an image scope applies only to a
  `RegionImageTransformer`. Everything else ignores it, so the "whole buffer" marking works as for text.

### Where the region lives

- `PanelView` owns `@State imageRegion: ImageRegion?`, beside `editorSelection` and never on the model
  (the #25 lesson). It passes a `Binding` into `ImageSessionView`, which draws it and handles the
  gestures.
- `currentScope` returns `.image(region, revision)` in an image session with a non-empty region, and the
  text scope otherwise.
- The region clears whenever the image entry changes (the `detectionRevision` moves) unless a pending
  region is supplied (next point). It also clears at every session boundary. That includes a history
  load, and a refused over-ceiling image, which has no image entry at all.

### Undo

- `AppModel.pendingImageRegion: PendingImageRegion?` (a region plus the revision it belongs to) mirrors
  #25's `pendingSelection`. `PanelView` consumes it when the image's revision matches, and clears it at
  session boundaries.
- `TransformStep` records the region before **any** apply made while a region was up (decision 6), not
  only a region transform. `stepBack` sets `pendingImageRegion` to it, so ⌘Z restores the image *and*
  the region. `stepForward` sets nothing, because after a crop the selection is clear.

### Gestures, in `ImageSessionView`

- **Where:** the gesture and the selection drawing are an `.overlay` on the `Image` after
  `.resizable().scaledToFit()`, inside the 12 pt padding. The overlay's geometry is then exactly the
  fitted image rect, with no letterbox offset to compute. It stays clear of the panel's move zone (the
  transparent titlebar strip, where the toolbar sits) and its resize edges. The panel isn't movable by
  its background.
- **One gesture:** `DragGesture(minimumDistance: 0)`, classified on end. Under 3 pt of travel is a tap: a
  tap outside the region clears it. Otherwise:
  - starting outside the region starts a new one;
  - starting inside moves it;
  - starting on one of the 8 handles (8 pt hit targets) resizes it.
  Two competing gestures (tap plus drag) is where SwiftUI gets flaky, and the default 10 pt minimum
  would turn a small drag into a tap.
- **Limits:** everything is clamped to the image, and the region is floored at 1 px. On a tiny image
  scaled up (a 16 px favicon is about 25 pt per pixel), the handles may overlap the region rather than
  shrink with it.
- **While applying or uploading:** the gesture layer is disabled
  (`.disabled(model.isApplying || isUploadOpen)`), so the region can't move while a crop is running
  and the recorded region matches what you see.
- **Esc** is `PanelView.escape()`'s job (decision 3): after the overlays and preview, before cancel. The
  panel's Esc is the Cancel button's key equivalent, and an image session has no focused view to
  receive a key handler.
- **Drawn Preview-style**, so it reads on dark, light and blue content alike (a 1 pt accent border
  vanishes over macOS blue, and 40% dimming over a dark terminal screenshot):
  - a two-tone outline (1 pt white over a 1 pt black hairline);
  - handles with a white fill, a dark 1 pt border and a small shadow;
  - the area outside the region dimmed about 50%.

## Out of scope

Aspect ratios or snapping; nudging with the arrow keys; redact/blur, resize, rotate and annotate
(later, on this foundation); Extract Text on a region; an image-edit pane.

## Testing

**Package:**
- `ImageRegion`: view ↔ pixel mapping at several scales and letterbox offsets; rounding outward;
  clamping; oriented size for orientations 1 and 6.
- `CropToSelection`, on a two-colour fixture:
  - the output size matches the region, and the colours are sampled at known pixels;
  - a Display P3 fixture keeps its profile (no colour shift);
  - no region → the note;
  - the whole image → the note;
  - an orientation-6 fixture (a PNG with an eXIf Orientation 6) crops the area that was drawn, not the raw one;
  - the output has no GPS.
- The coordinator:
  - an image scope reaches a region transformer;
  - it's ignored by plain image transforms;
  - a stale revision or out-of-bounds region is refused;
  - text scopes behave exactly as before, with the #25 suite unchanged apart from the rename.

**Hosted:**
- Crop with a region pushes the cropped image and note, and the region clears.
- ⌘Z restores the original and the region; ⌘⇧Z re-crops.
- ⌘Z after Strip Image Metadata applied with a region up restores the region too.
- A region is dropped when the image changes by other means (Strip Metadata applied).
- A refused over-ceiling session has no scope, even after an earlier image session had a region.
- After Extract Text, the scope is the text scope, not a stale image scope.
- Esc order, through `escape()`: an open palette closes first, then the region clears, then cancel.

**GUI pass (`work`):**
- The first drag on a non-key panel starts a region on that same mouse-down.
- Tap vs a small drag.
- Esc order: palette open, region up, nothing.
- Dark, mid-blue and white fixtures, for the outline and dimming.
- Drag, handles, move and clamp.
- Esc and click-outside clearing.
- The footer readout.
- The hint and the "whole buffer" marks in the palette and sidebar.
- Cropping a real screenshot and a rotated photo.
- Undo and redo.
