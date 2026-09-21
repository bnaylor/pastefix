---
type: spec
status: approved
id: 2026-08-11-pastefix-v2-foundation-pipeline
title: Pastefix v2 — Foundation + Transform Pipeline
description: Design for the initial v2 build — menubar app, global-hotkey panel, native text transforms, and a pluggable shell/JavaScript transformer pipeline.
tags: [pastefix, macos, swift, clipboard, pipeline]
timestamp: 2026-08-11T20:15:17Z
---

# Pastefix v2 — Foundation + Transform Pipeline

## Scope

This spec covers the **first** design increment of Pastefix v2: the app
foundation plus the transformer pipeline that is the conceptual heart of v2.

**In scope:**

- Non-sandboxed SwiftUI menu-bar app with a global-hotkey floating panel.
- An editable, plain-text working buffer summoned from the clipboard.
- A "palette of actions" interaction model: click transforms to apply them,
  stacking with undo/redo, then Save-to-clipboard or Cancel.
- Four built-in native transforms: rich→plain, transliterate/strip non-ASCII,
  wrap & reflow to width, whitespace cleanup.
- A unified `Transformer` protocol with three engines: native Swift, shell
  (stdin→stdout), and JavaScriptCore. User scripts discovered from
  `~/.config/pastefix/scripts/`.
- Settings, persistence, Sparkle auto-updates.

**Explicitly out of scope** (deferred to later specs with their dependent
features):

- Clipboard *history* / multi-item stack (Soon tier).
- Sensitive-app history *exclusion* — meaningless until history exists.
- Auto-paste into the previously focused app — the frontmost app is *captured*
  at summon but not used to paste in v1.
- URL tracking-parameter stripping and content auto-detection — these become
  pipeline transformers in a later increment.
- Selection-scoped transforms — v1 transforms operate on the whole buffer.

## Background

Pastefix (2007, Objective-C) was a menu-bar utility with a global hotkey whose
job was to clean text for pasting into IRC: strip/transliterate non-ASCII,
flatten rich text to plain, and wrap/split long lines. See
[`docs/inputs/legacy/README-2019.md`](../inputs/legacy/README-2019.md) and the
original [`TextProc-2007.m`](../inputs/legacy/TextProc-2007.m) for the classic
algorithms (iconv `ASCII//TRANSLIT` with a lossy fallback; line splitting on
word boundaries).

v2 is a category change, not an incremental update: from "invisible auto-cleaner"
to "clipboard power-tool." The full v2 roadmap was tiered (First/Soon/Later) in the original requirements document; it now lives as
[GitHub issues labelled `tier: first` / `tier: soon` / `tier: later`](https://github.com/bnaylor/pastefix/issues?q=is%3Aissue+label%3A%22tier%3A+first%22%2C%22tier%3A+soon%22%2C%22tier%3A+later%22) (the file was retired 2026-09-20 once its shipped items were done). This spec deliberately narrows to the
foundation and the pipeline so the shell/JS runtime surface is de-risked early.

## Distribution model

**Direct download, notarized DMG, non-sandboxed, Sparkle auto-updates.**

Rationale: the shell-script half of the pipeline, global hotkeys, and (future)
Accessibility auto-paste all fight the App Store sandbox. A non-sandboxed build
keeps every planned capability on the table. `LSUIElement = true` (no Dock icon
by default; menu-bar presence only).

## Architecture

### Backbone: unified `Transformer` protocol (pluggable engines)

One protocol; three conformances (native Swift, shell, JavaScript). The palette,
ordering, enable/disable, and hotkeys treat all three identically — they are
just `Transformer` values from different sources. Built-ins are compiled in;
scripts are discovered from disk. This is the only structure where "both engines
in v1" does not create duplicated apply/ordering/UI logic, and it keeps native
transforms native (fast, testable, able to read rich pasteboard content that a
shell script cannot see).

```swift
protocol Transformer: Identifiable {
    var id: String { get }
    var name: String { get }
    var requiresRichInput: Bool { get }    // true only for rich→plain
    var source: TransformerSource { get }   // .builtin / .shell(URL) / .javascript(URL)
    func apply(_ input: TransformInput) async throws -> String
}

struct TransformInput {
    let text: String
    let rich: NSAttributedString?
}

enum TransformerSource {
    case builtin
    case shell(URL)
    case javascript(URL)
}
```

`async throws` lets shell/JS process I/O and native synchronous calls share one
signature that the palette invokes uniformly.

### App shell & surfaces

- **`MenuBarExtra`** (SwiftUI): summon, toggle transforms, open Settings, Check
  for Updates, Quit.
- **Floating panel** (`NSPanel`, `.nonactivatingPanel` + `.floating` level):
  the working window summoned by the global hotkey. Holds the editor + transform
  palette. A panel (not a window) so it can appear over full-screen apps without
  switching Spaces.

**Global hotkey:** `KeyboardShortcuts` SPM package (Sindre Sorhus). Default
`⌘⇧C` (matching the original). Ships a recorder UI for Settings, which resolves
the Cmd-key capture problem the 2007 `NOTES` file documented.

**Summon sequence:**

1. Record `NSWorkspace.frontmostApplication` (stored for future auto-paste; not
   used in v1).
2. Snapshot the pasteboard, capturing both plain-text and rich (RTF/HTML)
   representations.
3. Load plain text into the editor, focus it, show the panel.

**Dismiss:**

- **Save** (`⌘S`): write the working text as plain text to the pasteboard, hide.
- **Cancel** (`Esc`): hide, pasteboard untouched.
- **Auto-hide-on-blur** (setting, default **on**): when the panel loses focus
  without an explicit Save/Cancel, it hides itself. Off keeps the panel put so
  the user can copy something else, return, Refresh, and continue. Matches the
  old "Autohide" preference.

### Document model, undo, and the working buffer

Rich→plain needs the original pasteboard, but the editor is plain-text. The
document therefore holds both the origin snapshot and a linear history of
working-text states.

```
PasteDocument
  origin: ClipboardSnapshot   // captured at summon: .rtf / .html / .string reps
  history: [String]           // stack of working-text states
  cursor: Int                 // index into history (undo/redo)
```

- `working` = `history[cursor]`; the editor binds to it.
- **Applying a transform** pushes a new state:
  `history[cursor+1] = transform(working)`, truncating any redo tail. Undo/redo
  = moving `cursor`.
- **Manual edits** coalesce into the current state (native text-view typing undo
  lives inside one state); committing an edit before applying a transform
  snapshots it. Net: one linear, predictable history regardless of whether a
  change came from a click or the keyboard.
- **Rich→plain is special:** it reads `origin` (the `NSAttributedString` from
  RTF/HTML), not `working`. It is enabled only when the snapshot actually
  contained rich content. Every other transform is `String → String` on
  `working`.
- **Refresh:** re-snapshot the pasteboard and reset history (for when the user
  copies something new while the panel is open).

**Design assertions:**

1. The editor is **plain-text only**. Rich content is read at load time for
   rich→plain, then the app lives in plain-text land. No rich editing — this
   matches Pastefix's purpose (producing clean plain text) and avoids an
   `NSAttributedString` editing rabbit hole.
2. Transforms operate on the **whole buffer**, not a selection, in v1.

## Built-in transforms (native Swift)

All four ship in the v1 palette. Implemented natively for speed, reliability,
and testability; rich→plain additionally needs native pasteboard access.

1. **Rich → plain text.** Flatten RTF/HTML clipboard content to plain text,
   dropping fonts/colors/styles. Reads `origin`; enabled only when rich content
   is present.
2. **Transliterate / strip non-ASCII.** iconv `ASCII//TRANSLIT`-style: `é`→`e`,
   smart quotes/dashes→ASCII, strip dingbats. The original raison d'être.
   Implemented via `Data`/`String` transliteration APIs (or `iconv`) with a
   lossy fallback, mirroring the 2007 behavior.
3. **Wrap & reflow to width.** Word-wrap long lines to a configurable column
   width; vim-`gq`-style reflow (rejoin a paragraph, then re-wrap). Subsumes the
   old IRC line-split behavior. Unit tests cover the boundary cases the original
   `doSplit` admitted were buggy.
4. **Whitespace cleanup.** Strip leading spaces, trim trailing whitespace,
   collapse repeated blank lines.

## Script pipeline

### Discovery

- Location: `~/.config/pastefix/scripts/` (overridable in Settings).
- Scanned at launch and watched via `FSEvents` — editing a script re-registers
  it with no app restart.
- Engine by file extension: `.sh`/`.py`/`.pl`/etc. → shell (respect the
  shebang; default `/bin/sh`); `.js` → JavaScriptCore.

### Metadata — magic-comment header

Self-contained, editable in-app, survives copy/paste between machines. Chosen
over sidecar JSON or a central manifest.

```
#!/bin/sh
# pastefix: name = Rot13
# pastefix: enabled = true
# pastefix: order = 50
```

JS uses the same keys inside a leading `/* ... */` block. Missing `name` →
filename. Unknown keys ignored.

### Contracts

- **Shell:** working text on **stdin** → transformed text on **stdout**.
  Non-zero exit → error (stderr surfaced to the user), buffer unchanged. Run
  with a timeout, a minimal scrubbed environment, and `cwd` = scripts dir.
- **JavaScript:** the script must define `function transform(text) { return … }`.
  Invoked in a fresh `JSContext` per call; a thrown JS exception → surfaced
  error.

### Execution & failure model (uniform)

Every apply runs off the main thread with a **configurable timeout (default
3s)**. Timeout / non-zero exit / JS exception / crash → the transform is a no-op
on the document, an inline error banner explains why, and undo history is
untouched. A transform can never corrupt the buffer or take down the app.

**Known limitation (accepted for v1):** JavaScriptCore has no clean way to
interrupt a runaway script (e.g. `while(true){}`). On timeout the result is
abandoned and the context detached, but that JS may keep occupying a background
thread until it finishes or the app quits. Shell timeouts are clean (kill the
process); JS is best-effort. This is why the default timeout is conservative.
Since scripts are user-authored, this is acceptable until JS can be sandboxed or
made interruptible in a later increment.

## Settings & persistence

SwiftUI Settings scene, persisted to `UserDefaults`:

- Global hotkey (`KeyboardShortcuts` recorder).
- Default wrap column width (the old IRC-length heuristic becomes a plain
  number; default ~400).
- Auto-hide-on-blur toggle (default on).
- Per-transform enabled + order — built-ins and scripts shown together in one
  list.
- Scripts directory path (default `~/.config/pastefix/scripts/`).
- Check for Updates (Sparkle).

**Source of truth:** enabled/order for **scripts** lives in their magic-comment
headers (on disk); for **built-ins** it lives in `UserDefaults`. The Settings
list writes back to whichever owns each row.

## Error handling summary

- Transform failure (timeout, non-zero exit, JS exception): no-op on document,
  inline error banner, undo history untouched.
- Rich→plain with no rich content available: transform disabled, not an error.
- Malformed script metadata: script still loads (name falls back to filename);
  parse issues are non-fatal.
- Missing/empty pasteboard at summon: panel opens with an empty buffer.

## Testing

Per `AGENTS.md`, `Tests/` must cover new features and edge cases.

- **Native transformers** — pure `String→String` (rich→plain takes an
  `NSAttributedString`); fixture-based unit tests including smart quotes,
  em-dashes, dingbats, CJK, and wrap/reflow boundary cases.
- **Metadata-header parser** — valid input, missing name, unknown keys,
  malformed lines.
- **Shell/JS runners** — fixture scripts in the test bundle: happy path,
  non-zero exit, timeout, JS exception, empty output.
- **Document/history model** — apply / undo / redo / refresh sequences.
- **UI** (panel, MenuBarExtra) — not unit-tested; manual verification.

## Project layout

```
Pastefix/            App shell, MenuBarExtra, panel, editor view (SwiftUI)
  Transform/         Transformer protocol, Native/Shell/JS engines, registry, discovery
  Model/             PasteDocument, ClipboardSnapshot, history
  Settings/          Settings UI + persistence
Tests/               Transform, model, parser tests
docs/                specs/, plans/, reviews/ per AGENTS.md
```

## Dependencies (SPM)

- `KeyboardShortcuts` (Sindre Sorhus) — global hotkey + recorder UI.
- `Sparkle` — auto-updates.

JavaScriptCore and everything else are system frameworks.

## Open questions / future increments

- URL tracking-parameter stripping and content auto-detection (First tier) as
  pipeline transformers.
- Clipboard history + multi-item stack, and sensitive-app exclusion (Soon).
- Auto-paste into the previously focused app via Accessibility.
- Selection-scoped transforms.
- Zipline upload, Markdown preview, image/OCR handling (Soon/Later).
