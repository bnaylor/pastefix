# PastefixCore

PastefixCore is a macOS clipboard transform engine that unifies native Swift transforms, shell scripts, and JavaScript functions under a single `Transformer` protocol. It powers the transform pipeline of Pastefix v2, a clipboard utility that applies transformations on demand.

> **Note:** This package documents the transform engine. The Pastefix v2 app UI is described in the section below.

## The app (Plan 2a)

Pastefix runs as a macOS menu-bar app. A clipboard icon sits in the menu bar; pressing **⌘⇧C** summons a floating panel over whatever app is in the foreground (no Space-switch, no Dock icon).

**Install:** download the latest notarized DMG from [GitHub Releases](https://github.com/bnaylor/pastefix/releases), drag Pastefix to Applications. The app keeps itself up to date via Sparkle.

**Core flow:**

1. **Summon** — ⌘⇧C snapshots the clipboard and opens the editor panel.
2. **Transform** — a horizontal palette of buttons along the bottom of the panel lists every enabled transformer (built-ins + user scripts). Click one to apply it; the monospaced editor updates instantly. An error banner appears in red if a transformer fails.

   **Content detection.** When the buffer contains a URL or is valid JSON, a `Detected: URL` badge appears beside the palette and transforms that apply to that kind are listed first. Nothing is hidden; your enable/reorder settings still apply.

3. **Edit** — the editor is freely editable. Undo/Redo/Refresh controls are in the toolbar.
4. **Save (⌘S)** — writes the working text back to the clipboard and dismisses the panel.
5. **Cancel (Esc)** — discards changes and dismisses the panel.

## Settings (Plan 2b)

Pastefix includes a Settings window (⌘, or "Settings…" in the menu) with three tabs:

- **General:** Configure wrap width (default 400 columns), toggle auto-hide-on-blur (dismisses the panel when focus leaves), and choose a custom folder for user scripts (default `~/.config/pastefix/scripts/`).
- **Shortcut:** Rebind the global hotkey (default ⌘⇧C) using an interactive keyboard recorder.
- **Transforms:** Enable/disable individual transforms and drag to reorder them in the palette.

All settings persist via `UserDefaults`. User scripts are watched for changes; editing a script under `~/.config/pastefix/scripts/` updates the palette instantly without relaunch.

### Updates (Plan 2c)

Pastefix checks for updates once a day via [Sparkle](https://sparkle-project.org) and asks before installing anything. **Check for Updates…** in the menu bar runs a check on demand; Settings → General has an **Automatically check for updates** toggle, a **Check Now** button, and the installed version. Updates are EdDSA-signed and Developer-ID-verified; the feed is `https://bnaylor.github.io/pastefix/appcast.xml`. Maintainers: see [docs/RELEASING.md](docs/RELEASING.md).

## Overview

The engine provides:

- **Ten built-in native transforms** written in Swift, fast and dependency-free
- **User scripts** discovered from `~/.config/pastefix/scripts/`, with automatic engine selection (shell or JavaScript) by file extension
- **Unified error handling** via typed `TransformError`; all transforms run off the main thread with configurable timeouts
- **Script metadata** via magic comments (name, enabled flag, execution order)
- **Filesystem watching** with debouncing for dynamic script discovery
- **Content detection** — the panel recognises URLs and JSON and lists the transforms that apply to them first

## Built-in Transforms

Each is a zero-configuration `Transformer` conforming to the protocol:

- **Rich → Plain Text:** Extracts plain text from rich RTFD data (requires original clipboard rich content; others work on the text buffer).
- **Transliterate to ASCII:** Converts smart punctuation, diacritics, and non-ASCII characters to ASCII equivalents (e.g., é → e, "curly quotes" → straight quotes, emoji dropped).
- **Wrap & Reflow:** Rewraps text to a configurable width (default 400 columns), respecting paragraph breaks.
- **Whitespace Cleanup:** Trims leading/trailing spaces and tabs from each line; collapses repeated blank lines.
- **Clean URL Tracking:** Removes tracking parameters (`utm_*`, `fbclid`, `gclid`, `si`, `mc_cid`, … ) from every URL in the text; other parameters, fragments, and surrounding text are untouched. HTML-escaped `&amp;` query separators (as found in links copied from email or HTML source) are normalised to `&` before stripping, which counts as a change on its own.
- **URL → Markdown Link:** Replaces each URL with `[Page Title](url)`. The title is fetched over the network with a 3-second timeout and a 256 KB cap; if that fails the link text is `host/path`. URLs already inside Markdown links are skipped. Up to 16 unique URLs per apply are fetched; any beyond that fall back to `host/path` without a network call. The link target always includes a scheme, so `www.example.com` becomes `[…](http://www.example.com)`. Titles are always fetched over `https`, even for an `http://` link (App Transport Security blocks cleartext, so a plain-`http` fetch could only ever fail) — the link target keeps the scheme the text had. Requests carry a `Pastefix` User-Agent and no cookies, and local or private hosts (`localhost`, `*.local`, loopback, and the RFC 1918 ranges) are never contacted: those links just get the `host/path` fallback.
- **camelCase / snake_case / kebab-case / CONSTANT_CASE:** Rewrites each line as one identifier phrase. Splits on separators and camel boundaries (`HTTPServerError` → `http_server_error`), keeps digits with their word (`utf8Decoder`), preserves indentation and non-ASCII letters.

## User Scripts

Scripts are discovered automatically from `~/.config/pastefix/scripts/`. The engine selects the interpreter by file extension:

- **`.js` files** → JavaScriptCore
- **Any other extension** (or no extension) → shell, honored by shebang

### Shell Script Contract

A shell script receives the working text on stdin and must write the transformed text to stdout:

```bash
#!/bin/bash
# pastefix: name = Uppercase
tr '[:lower:]' '[:upper:]'
```

- **Input:** text on stdin
- **Output:** transformed text on stdout
- **Error handling:** non-zero exit code signals an error; stderr is captured and surfaced in the error
- **Environment:** minimal (`PATH`, `HOME` only); runs in the script directory; the shebang is honored by the kernel
- **Timeout:** configured per registry (default 3 seconds); on timeout, the shell process is sent SIGTERM, then SIGKILL after a 0.5 s grace period — a hard upper bound that fires even if the script traps SIGTERM. Contrast with JavaScript, which cannot be interrupted and is abandoned best-effort.

### JavaScript Contract

A JavaScript file must define a top-level `function transform(text)` that returns the transformed string:

```javascript
/* pastefix: name = Reverse */
function transform(text) {
    return text.split('').reverse().join('');
}
```

- **Input:** text passed as the sole argument to `transform(text)`
- **Output:** the return value must be a string
- **Error handling:** exceptions or non-string returns are caught and surfaced as script errors
- **Context:** JavaScript runs in a fresh JSContext per invocation; no globals or state persist between calls
- **Timeout caveat:** JavaScriptCore cannot be interrupted. If a JS script runs past the timeout, the best-effort strategy is to abandon the continuation and let the thread finish on process exit. Shell scripts, by contrast, receive SIGTERM followed by SIGKILL after a short grace period, enforcing a hard upper bound on wall-clock duration.

## Script Metadata

Magic comments in the first 30 lines define script behavior. Recognized keys are `name`, `enabled`, and `order`:

```bash
#!/bin/bash
# pastefix: name = My Transform
# pastefix: enabled = true
# pastefix: order = 500
```

```javascript
/* pastefix: name = My JS Transform, order = 600 */
```

- **Comment syntax:** lines are tolerant of comment markers (`#`, `//`, `*`, `/*`); the parser strips leading whitespace and any run of the individual characters space, tab, `#`, `/`, `*`
- **Keys:** `name` (display name), `enabled` (true/false; default true), `order` (integer execution order; default 1000 for scripts), `kinds` (comma-separated list of `url`, `json`; a script with `kinds` is listed first when that content is detected; unknown names ignored)
- **Built-in order:** Rich→Plain (10), Transliterate (20), Wrap (30), Whitespace (40), Clean URL Tracking (50), URL → Markdown Link (60), camelCase (70), snake_case (71), kebab-case (72), CONSTANT_CASE (73); user scripts at order 1000+ appear after built-ins unless explicitly reordered
- **Malformed lines:** ignored silently

## Execution Model

All transforms run off the main thread via Swift's async/await:

```swift
let transformer: any Transformer = ...
let input = TransformInput(text: "Hello", richRTFD: nil)
let result = try await transformer.apply(input)
```

- **Timeout:** default 3 seconds per `RegistryConfig`; a timed-out transform throws `TransformError.timeout`
- **Errors:** `TransformError` is a typed enum with cases for rich input unavailable, timeout, non-zero shell exit (carrying exit code + stderr), and script exceptions
- **State safety:** failed or timed-out transforms never corrupt engine state; errors bubble to the caller for handling

## Script Discovery & Registry

The `TransformerRegistry` loads all enabled transforms in priority order:

```swift
let config = RegistryConfig(
    scriptsDirectory: URL(fileURLWithPath: NSHomeDirectory() + "/.config/pastefix/scripts"),
    timeout: 5
)
let registry = TransformerRegistry(config: config)
let transformers = registry.load()  // [any Transformer], in order
```

- **Discovery:** scans the scripts directory for regular files; hidden files are skipped
- **Missing directory:** tolerated; registry returns only built-ins
- **Ordering:** built-ins and scripts are sorted by (order, name); executed in that order
- **Disabling:** scripts with `enabled = false` in their metadata are excluded

## Testing

Run the full test suite:

```bash
swift test
```

The suite includes 35 tests covering all transforms, shell and JavaScript execution, metadata parsing, filesystem watching with debouncing, error cases, and registry loading.

## Example Scripts

### Shell: Uppercase Transform

```bash
#!/bin/bash
# pastefix: name = Shout
tr '[:lower:]' '[:upper:]'
```

### JavaScript: JSON Pretty-Print

```javascript
/* pastefix: name = Format JSON */
function transform(text) {
    try {
        const obj = JSON.parse(text);
        return JSON.stringify(obj, null, 2);
    } catch (e) {
        throw new Error("Invalid JSON: " + e.message);
    }
}
```
