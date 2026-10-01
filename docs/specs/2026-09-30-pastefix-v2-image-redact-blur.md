# Redact and blur a region, plus two region-selection fixes

**Status:** approved design, 2026-09-30. It's the second of the image edits, after crop (#128). The
owner's order after this: rotate/flip, then resize/scale/format/compression (#21), then annotate.
Owner decisions are marked **(owner)**.

## Goal

Select a region on an image, as for crop, then either:
- choose **Redact Selection** to cover it with a solid black box, or
- choose **Blur Selection** to blur it.

Both are one undo step, and ⌘Z restores the image and the region. This round also fixes two
region-selection problems deferred from crop's final review, because redacting small things
makes them worse.

## Decisions

1. **Redact is the safe tool, blur is cosmetic (owner).**
   - Blurred or pixelated screenshot text can often be reconstructed, so only Redact claims to
     hide anything.
   - Blur's description and its result note say it can be reversed and point at Redact.
   - A secret-triggered warning (read the region's text, run the secret patterns) is a
     follow-up, #129. It's out of scope here.
2. **Fill is opaque black.** It's the conventional redaction bar: it reads as a redaction on any
   image and carries nothing from the region. Where the image has alpha, the region becomes
   opaque black.
3. **Blur is a Gaussian blur of the region only.**
   - The radius is 5% of the region's shorter side, at least 6 px.
   - The blur samples only the region, with its edges clamped, so nothing outside smears in and
     nothing outside changes.
4. **The same contract as crop** (crop spec decisions 5–7):
   - Both transforms are listed in every image session, in the Images category.
   - With no region, each explains what to do (below).
   - A result is one undo step. ⌘Z restores the image and the region; ⌘⇧Z re-applies.
   - The region clears after applying.
   - EXIF orientation is baked in. The colour profile is kept. Metadata is dropped (re-encoded
     through `PNGEncoder`). Save writes the PNG, never the origin's rich representation.
5. **A whole-image region is allowed.** Unlike crop, blacking out or blurring the whole picture
   is a real result, not "nothing to do".
6. **Deliberately out:** a fill-colour choice, pixelate, several regions at once, the secret
   warning (#129).

## Design

### The transforms (PastefixCore)

| | Redact Selection | Blur Selection |
|---|---|---|
| id | `builtin.redactselection` | `builtin.blurselection` |
| order | 114 | 115 |
| no region | `.nothingToDo("Drag on the image to choose what to hide, then choose Redact Selection.")` | `.nothingToDo("Drag on the image to choose what to blur, then choose Blur Selection.")` |
| result note | `"Redacted w×h."` | `"Blurred w×h. Blur can be reversed; use Redact Selection to hide something for good."` |

Both are `RegionImageTransformer`s, with category Images and accepted forms `[.image]`. They run
on the shared image lane like every image transform.

- A region that doesn't fit the image's oriented size throws the same `invalidInput` crop uses.
  The coordinator's stale-region refusal still happens first.
- **Shared decode:** crop's oriented full-size decode moves into one helper. It reads the
  properties on the source, then makes a `WithTransform` thumbnail at full size on the *same*
  source. That's the ImageIO quirk crop found: otherwise a PNG's eXIf orientation isn't applied.
  The helper returns the oriented `CGImage` and refuses if the decode's size differs from the
  oriented header size. Crop, Redact and Blur all use it.
- **Redact:** draw the oriented image into a bitmap context in the image's own colour space,
  then fill the region's rectangle with opaque black. The region's origin is top-left; the
  context's is bottom-left. Encode with `PNGEncoder`.
- **Blur:** use Core Image.
  1. Crop the region out.
  2. `clampedToExtent`.
  3. `CIGaussianBlur` at the radius above.
  4. Crop back to the region and composite over the original.
  5. Render in the image's colour space, then encode with `PNGEncoder`.
  6. Only pixels inside the region may change.
- **Where they go:**
  - registry orders 114 and 115;
  - the limits table, `(defaultMaxInputBytes, 10)` like the other image transforms;
  - `TransformerRegistryTests` (count 31 → 33).

### Region selection fixes (app)

- **Small regions can be moved** (crop final review M2).
  - Today a handle's 8 pt hit box beats "inside", so in a region under about 16 pt every
    interior point resizes.
  - New rule in `RegionGeometry.hit`: a press inside the region goes to a handle only when the
    region is at least **24 pt** on both sides. Otherwise a press inside moves it.
  - A press *outside* the region but within 8 pt of a handle resizes, at any size. So a small
    region is resized from the outer half of its handles and moved from inside.
- **No stale drag state** (crop final review M1).
  - Today `dragHit` and `dragOriginal` are `@State`, reset only in `onEnded`. A cancelled
    gesture never runs `onEnded`: the panel losing key, or `.disabled` flipping when a
    transform starts. The next drag then replays the old hit against the old region.
  - They move to `@GestureState`, which SwiftUI resets on end *and* cancel.
  - `onEnded` classifies a tap from the gesture's own start location against the current
    region. A tap doesn't change the region, so it needs no stored state.

## Out of scope

Fill colours, pixelate, multiple regions per apply, the secret warning (#129), the other image
edits.

## Testing

**Package:**
- **Redact**, on a two-colour fixture:
  - every pixel in the region is black;
  - every pixel outside is byte-identical to the input;
  - a whole-image region gives an all-black image;
  - an orientation-6 fixture redacts the displayed area, not the stored one;
  - a Display P3 input stays P3;
  - no GPS in the output;
  - the no-region note.
- **Blur:**
  - pixels outside the region are byte-identical;
  - inside, the region changed and isn't uniform. Blur, not fill: on a striped fixture the
    stripes' contrast drops by at least half;
  - the orientation, profile, metadata and no-region cases as above.
- **Shared decode:** crop's existing tests pass unchanged after the move.
- **`RegionGeometry.hit`:**
  - inside a 10×10 pt region → move;
  - just outside its corner → that handle;
  - inside a 100×100 pt region near a corner → the handle.

**Hosted:**
- Real mouse events: a 10×10 pt region moves by dragging inside, and keeps its pixel size.
- Redact applied through the panel with a region up: note, entry pushed, region cleared, ⌘Z
  restores the region.

**GUI pass (with the owner's OK):**
- Redact and blur on dark, blue and white fixtures.
- Blur on a real screenshot with text: is the text unreadable at a glance?
- Move and resize of a small region.
- Undo and redo.
- The marks in the palette and sidebar.
