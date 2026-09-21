# Pastefix icon

A modern redesign of the original (2001) Pastefix icon — the claw hammer laid
across a dark display. Rebuilt as vector art on the macOS icon grid.

## What's here

| Path | What it is |
|---|---|
| `pastefix-{A,B,C}.svg` | Editable vector source, 1024×1024. The authority — regenerate any raster from these. |
| `pastefix-{A,B,C}.icns` | Ready-to-use icon files (16→1024, all `@2x` variants). |
| `appiconset-{A,B,C}/` | Drop-in replacements for `AppIcon.appiconset`. |
| `previews/` | 1024px PNGs for eyeballing. |
| `MenuBarIcon.imageset/` | Template image for the status-bar item (see below). |

The three concepts:

- **A — Display.** The faithful descendant of the 2001 icon: light bezel, dark
  inset screen, hammer across it. Highest contrast, so it holds up best at 32pt.
- **B — Clipboard.** Same hammer, but the tile is a clipboard. Says what the app
  actually does now. *Currently wired into the build.*
- **C — Graphite.** Dark tile, hammer, faint text. The most restrained; note it
  has the least separation against a dark Dock.

## Geometry

Built to Apple's icon grid rather than eyeballed:

- 1024×1024 canvas, artwork confined to the centred **824×824** tile
  (100pt transparent margin on every side).
- Corner radius **185.4** with **0.6 corner smoothing** — the continuous-curvature
  squircle, not a plain rounded rect, so it sits correctly beside system icons.
- **Straight alpha, no baked drop shadow.** macOS composites its own shadow; a
  baked one doubles up and reads as a smudge. The only shadow in the art is the
  hammer's own contact shadow *onto* the tile, clipped to the tile.
- Nothing overhangs the tile. Big Sur-era icons often broke the edge, but a
  contained icon survives Tahoe's Icon Composer masking unchanged.

## Regenerating

The `.svg` files are standalone and self-contained — no external fonts or
images, and the contact shadow is a real `feDropShadow` filter, so they open
correctly in Illustrator, Sketch, Figma or Icon Composer.

To rebuild rasters from a source on macOS:

```sh
# one size
rsvg-convert -w 1024 -h 1024 pastefix-B.svg -o icon_512x512@2x.png

# a full .icns
mkdir pastefix.iconset
for s in 16 32 128 256 512; do
  rsvg-convert -w $s        -h $s        pastefix-B.svg -o pastefix.iconset/icon_${s}x${s}.png
  rsvg-convert -w $((s*2))  -h $((s*2))  pastefix-B.svg -o pastefix.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns pastefix.iconset
```

## Menu bar

`MenuBarIcon.imageset` is a **template image** (black + alpha; macOS recolours it
for light/dark and for the highlighted state). It's a clipboard mark, not the
hammer — at 18pt the hammer's claw collapses into an unreadable squiggle, so the
status item carries the simpler half of the idea.

Use it as `NSImage(named: "MenuBarIcon")`; `isTemplate` is already set via the
imageset's `template-rendering-intent`, so don't tint it yourself.

## Swapping concepts

```sh
cd Pastefix/Pastefix/Assets.xcassets
rm -rf AppIcon.appiconset && cp -R ../../../design/icon/appiconset-A AppIcon.appiconset
```

(substituting `-A` or `-C`), then clean-build so Xcode re-reads the catalog.
