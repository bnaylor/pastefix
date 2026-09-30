# Image crop, and the region selection image edits build on

**Status:** approved design, 2026-09-30. It's the first of the image edits the owner wants: crop, then
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
   replaces it.
4. **Readout:** while a region exists, the footer reads `W×H · size · Selection w×h at (x, y)` in real
   image pixels, not the scaled display.
5. **Crop to Selection is always listed** (in the Images category), so it can be found. With no region,
   applying it is `.nothingToDo("Drag on the image to choose what to keep, then choose Crop to
   Selection.")`.
6. **The result** is a new image entry with the note "Cropped to w×h.", one undo step. ⌘Z restores the
   original image *and* the region; ⌘⇧Z re-crops. After a crop the selection is clear.
7. **Metadata:** crop re-encodes through `PNGEncoder`, so image metadata is dropped. That's consistent
   with Strip Image Metadata, and a privacy plus.
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
  5–8. A shared helper computes it, used by the view's footer and by the coordinator.

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
  2. Otherwise, decode at full size with orientation applied (the sanitizer's oriented decode),
     `CGImage.cropping(to:)`, `PNGEncoder.encode`.
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
  region is supplied (next point). It also clears at every session boundary.

### Undo

- `AppModel.pendingImageRegion: PendingImageRegion?` (a region plus the revision it belongs to) mirrors
  #25's `pendingSelection`. `PanelView` consumes it when the image's revision matches, and clears it at
  session boundaries.
- `TransformStep` records the region before a region transform. `stepBack` sets `pendingImageRegion` to
  it, so ⌘Z restores the original image *and* the region. `stepForward` sets nothing, because after a
  crop the selection is clear (decision 6).

### Gestures, in `ImageSessionView`

- A `DragGesture` on the fitted image:
  - starting outside the region starts a new region;
  - starting inside it moves it;
  - starting on one of the 8 handles (8 pt hit targets) resizes it.
- Everything is clamped to the image.
- A tap outside the region clears it. `onKeyPress(.escape)` clears it first, before the panel's Esc
  handling, the way the palette consumes Esc first.
- Drawn as a 1 pt accent-colour border with handles, with the area outside dimmed at 40% black.

## Out of scope

Aspect ratios or snapping; nudging with the arrow keys; redact/blur, resize, rotate and annotate
(later, on this foundation); Extract Text on a region; an image-edit pane.

## Testing

**Package:**
- `ImageRegion`: view ↔ pixel mapping at several scales and letterbox offsets; rounding outward;
  clamping; oriented size for orientations 1 and 6.
- `CropToSelection`, on a two-colour fixture:
  - the output size matches the region, and the colours are sampled at known pixels;
  - no region → the note;
  - the whole image → the note;
  - an orientation-6 fixture crops the area that was drawn, not the raw one;
  - the output has no GPS.
- The coordinator:
  - an image scope reaches a region transformer;
  - it's ignored by plain image transforms;
  - a stale revision or out-of-bounds region is refused;
  - text scopes behave exactly as before, with the #25 suite unchanged apart from the rename.

**Hosted:**
- Crop with a region pushes the cropped image and note, and the region clears.
- ⌘Z restores the original and the region; ⌘⇧Z re-crops.
- A region is dropped when the image changes by other means (Strip Metadata applied).

**GUI pass (`work`):**
- Drag, handles, move and clamp.
- Esc and click-outside clearing.
- The footer readout.
- The hint and the "whole buffer" marks in the palette and sidebar.
- Cropping a real screenshot and a rotated photo.
- Undo and redo.
