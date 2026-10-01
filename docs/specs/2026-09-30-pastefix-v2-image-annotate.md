# Annotate: markup mode for images

**Status:** approved design, 2026-09-30. It's the last of the owner's image edits, after crop (#128),
redact/blur (#130), rotate/flip (#131) and resize (#133). Owner decisions are marked **(owner)**.

## Goal

Mark up a screenshot in the panel before pasting it: box something, point an arrow at it, add a
short label, highlight a line, or scribble a rough oval around it. A handful of quick marks, not
a drawing program.

## Decisions

1. **Five tools (owner):** Box, Arrow, Text, Highlighter, Freehand.
2. **Marks are burned in when drawn, one undo step each (owner).** A finished mark becomes part of
   the image at once. ⌘Z removes the last mark. Nothing is moved, restyled or retyped afterwards.
3. **Markup mode with a tool strip (owner).**
   - A toolbar button and **⌘⇧A** (Preview's Markup shortcut, unbound in Pastefix) toggle markup
     mode.
   - The mode shows a compact strip above the image: the five tools, five colour swatches and
     **Done**.
   - In markup mode a drag on the image draws. Outside it, a drag selects a region as today.
   - This is the "image edit pane" question from the crop spec, answered light: a strip in the
     panel, not a separate editor.
4. **Each mark is a transform (owner, approach A).**
   - Marks go through the existing transform pipeline: the coordinator, the image lane, one undo
     step, and the region and undo machinery.
   - There is no second, view-side flattening path, so it's one pipeline, tested in Core.

## Design

### Tools and how they look

| Tool | Gesture | Mark |
|---|---|---|
| Box | drag | outline rectangle, corners at press and release |
| Arrow | drag from tail to tip | straight line with a filled triangular head at the release end |
| Text | click | a one-line text field at the click point. Return burns it in, Esc discards it, an empty field is discarded |
| Highlighter | drag a rectangle | translucent yellow fill, multiply blend, so dark text stays dark |
| Freehand | drag | the pointer's path, smoothed, round caps and joins |

- **Colours:** red (the default), yellow, blue, black, white. The highlighter always uses its own
  yellow and ignores the swatch.
- **Sizes scale with the image**, so a mark looks alike on a 400 px crop and a 5K screenshot. With
  `L` = the image's longer side in pixels:
  - stroke width = `max(2, round(L / 250))` px;
  - arrowhead length = 4 × the stroke width, and its width = 3 × the stroke width;
  - text = bold system font at `max(12, round(L / 40))` px;
  - the text halo = `max(1, round(stroke / 2))` px.
- **The halo** is drawn under the text, in white for dark colours and black for white and yellow,
  so a label reads on any background.
- **Too-small marks are discarded:**
  - a drag under 3 pt of travel (the region overlay's tap threshold) draws nothing for Box, Arrow,
    Highlighter or Freehand;
  - a Box or Highlighter with a zero width or height is discarded.
- **Freehand smoothing:**
  - points closer than 1 pt to the previous kept point are dropped;
  - the path is drawn as quadratic curves through the midpoints of successive points.

### Coordinates

- A mark's points are in the image's **oriented pixels**, top-left origin, the same space as
  `ImageRegion`. The overlay maps view points to pixels with the header's pixel size (crop's
  rule), never the displayed bitmap's.
- Widths, sizes and offsets are in image pixels, computed from `L` above, so they're independent
  of the zoom.

### The transform (PastefixCore)

- `ImageMark`: `Sendable`, `Equatable`, `Codable`. It holds:
  - `tool`: box, arrow, text, highlight or freehand;
  - `color`: red, yellow, blue, black or white;
  - `points`: `[ImagePoint]` with `Int` x and y. Box, arrow and highlight use two points;
    freehand uses one or more; text uses one, the baseline origin's top-left;
  - `text`: `String?`.
- `AnnotateImage: ImageTransformer` holds one `ImageMark`.
  - Its `name` is the tool's name ("Box", "Arrow", "Text", "Highlight", "Freehand"), which the
    undo action shows.
  - It decodes through `OrientedSource`, draws the image and then the mark into
    `OrientedSource.bitmap(for:)`, keeping colour space and depth, and encodes with `PNGEncoder`,
    which drops metadata.
  - Its result note is the tool's past tense: "Box added.", "Arrow added.", "Text added.",
    "Highlight added.", "Drawing added."
- **Not registered:** it never appears in ⌘K or the sidebar, and usage ranking (#124) doesn't
  record it. Only markup mode applies it, through `AppModel.apply`.
- **The drawing code is pure and Core-side,** in `MarkRenderer`. The geometry is unit-tested:
  arrowhead points, smoothing, size scaling. The pixels are unit-tested on fixtures.
- **Text is drawn with Core Text,** so it's available in the package and its tests.

### Markup mode (app)

- **State:** `PanelView` holds `@State markupMode: Bool`, `markupTool` and `markupColor`.
  - Tool and colour persist for the app's run, as `AppModel` properties that aren't `@Published`
    and aren't saved to disk.
  - The mode is view state, like the region.
- **The button:** shown only when the current entry displays as an image. ⌘⇧A toggles the mode,
  and does nothing outside image sessions.
- **Entering** clears the region, and the region overlay is replaced by `MarkupOverlay`.
- **Leaving:** Done, ⌘⇧A or Esc. Leaving applies any queued marks first.
- **The mode turns off when:**
  - a session ends (`sessionGeneration`);
  - the entry stops displaying as an image, for example after Extract Text;
  - the upload overlay opens.
- **Esc order** in `escape()`:
  1. palette, history, upload;
  2. preview;
  3. the open text field, which is discarded;
  4. markup mode, which leaves;
  5. the region;
  6. cancel.
- **`MarkupOverlay`** sits on the fitted image, like `ImageRegionOverlay`:
  - one `DragGesture(minimumDistance: 0)`, with the drag start in `@GestureState`;
  - a live preview of the mark being drawn, as SwiftUI paths in view points, with sizes scaled
    from the image size by the display scale.
- **The queue:**
  - a finished mark is appended to `pendingMarks` (view state) and drawn as a preview;
  - the head of the queue is applied when the model isn't applying, and each apply is one undo
    step;
  - marks finished while an apply runs wait their turn, so nothing is dropped;
  - a failed apply drops its mark and shows the model's error as usual;
  - the queue is cleared at session boundaries.
- **The overlay is not disabled while applying.** Unlike the region overlay, drawing must
  continue. The queue is what keeps the order.
- **Text entry:**
  - a click with the Text tool opens a single-line `TextField` at the click point, scaled to the
    final text size;
  - Return finishes it and queues the mark;
  - clicking elsewhere on the image also finishes it, and that click doesn't start a new mark;
  - Esc discards it.
- **Undo:** ⌘Z while in markup mode removes the last applied mark, as normal undo, and the mode
  stays open. Queued marks not yet applied aren't undone. A mark applies within a fraction of a
  second, so "the last applied" is what the user sees.

### Docs

- README: a Markup paragraph in Images.
- AGENTS.md: the file map entries, the Esc order, the queue rule, and that `AnnotateImage` isn't
  registered.

## Out of scope

- Moving or editing marks after drawing.
- Line-width or font choices.
- Shapes beyond the five tools.
- Multi-line text.
- A separate edit pane.
- Persisting the tool and colour across launches.

## Testing

**Package:**
- **`MarkRenderer` geometry:**
  - stroke and text sizes for several `L`, including the minimums;
  - arrowhead points for horizontal, vertical and diagonal arrows;
  - freehand smoothing drops near-duplicate points and keeps the endpoints.
- **`AnnotateImage` pixels**, for each tool on an opaque fixture:
  - pixels change near the mark and nowhere outside the mark's padded bounding box;
  - Box leaves its interior unchanged;
  - Highlighter over black text keeps the text black and turns the white background yellow;
  - Text changes pixels inside its expected bounds;
  - an orientation-6 fixture marks the displayed position;
  - P3 and 16-bit inputs keep their space and depth;
  - no GPS in the output;
  - notes and names.

**Hosted, with real mouse events:**
- ⌘⇧A and the button toggle markup mode, which only exists in image sessions.
- Entering clears the region.
- A Box drag pushes one entry with the note "Box added.", and Undo removes it.
- Two drags in quick succession both land, as two undo steps.
- The Esc order:
  - with the text field open, Esc discards it and the mode stays;
  - Esc again leaves the mode;
  - then Esc cancels.
- The mode turns off at a session boundary.

**GUI pass (with the owner's OK):**
- every tool and colour on dark, blue and white screenshots;
- text legibility;
- the highlighter over real text;
- the freehand oval;
- fast successive strokes;
- undo and redo;
- the shortcut;
- how the strip looks.
