# PastefixCore

PastefixCore is a macOS clipboard transform engine that unifies native Swift transforms, shell scripts, and JavaScript functions under a single `Transformer` protocol. It powers the transform pipeline of Pastefix v2, a clipboard utility that applies transformations on demand.

> **Note:** This package documents the transform engine. The Pastefix v2 app UI is described in the section below.

## The app (Plan 2a)

Pastefix runs as a macOS menu-bar app. A clipboard icon sits in the menu bar; pressing **⌘⇧C** summons a floating panel over whatever app is in the foreground (no Space-switch, no Dock icon).

**Install:** download the latest notarized DMG from [GitHub Releases](https://github.com/bnaylor/pastefix/releases), drag Pastefix to Applications. The app keeps itself up to date via Sparkle.

**Core flow:**

1. **Summon** — ⌘⇧C snapshots the clipboard and opens the editor panel.
2. **Transform** — a "Transform… ⌘K" bar along the bottom of the panel opens an in-panel command palette listing every enabled transformer (built-ins + user scripts). Click a result, or press ↵ on the selected one, to apply it; the monospaced editor updates instantly. An error banner appears in red if a transformer fails.

   **Finding transforms.** Press ⌘K (or click the Transform… bar) for a command palette: type to filter, ↑↓ to choose, ↵ to apply, Esc to close; transforms that apply to the detected content are listed first. Typing matches a prefix, a word start, or (failing those) a loose subsequence — camel-case boundaries count as word starts too, so typing `case` finds `camelCase`. Esc closes the palette first; only a second Esc (with the palette already closed) cancels the panel. Toggle the sidebar (⌘⇧L or the toolbar button) to browse all enabled transforms grouped by category; the sidebar state is remembered. The panel window is resizable: it widens by the sidebar's width when the sidebar opens and gives that width back when it closes, so the editor doesn't get squeezed — and you can also resize the window yourself. The sidebar always keeps your configured order, so it doesn't reshuffle as you copy different things; the ⌘K palette lists transforms that apply to the detected content first.

   **Content detection.** When the buffer matches a recognised kind, a `Detected: …` label appears beside the Transform… bar and transforms that apply to that kind are listed first in the ⌘K palette. (The sidebar deliberately stays in your configured order.) Nothing is hidden; your enable/reorder settings still apply. Recognised kinds:

   - **URL** — the buffer contains a link.
   - **JSON** — the whole buffer parses as JSON.
   - **Color** — the whole buffer is a colour literal (`#hex`, `rgb()`, `hsl()`, …); a 14×14 swatch showing the colour appears next to the badge.
   - **JWT** — the whole buffer is three base64url segments whose header decodes to JSON with an `alg` key.
   - **Base64** — the whole buffer is 16+ characters that decode to printable text.
   - **Percent-encoded** — the buffer contains a `%XX` sequence.
   - **HTML entities** — the buffer contains a `&name;` or `&#n;` reference.

   A decode transform that can't interpret its input shows a red error banner and leaves the text unchanged.

3. **Edit** — the editor is freely editable. Undo/Redo/Refresh controls are in the toolbar.
4. **Save (⌘S)** — writes the working text back to the clipboard and dismisses the panel.
5. **Cancel (Esc)** — discards changes and dismisses the panel.

## Clipboard history (Plan 6)

Pastefix remembers what you copy: plain text, formatted (rich) text, and images, up to 200 items and 50 MB total (256 KB per text item, 1 MB per rich item, 5 MB per image; oversize items are dropped, not truncated). Press **⌘⇧V** anywhere, or **⌘Y** inside the panel, to open the history overlay and search it — type to filter, ↑↓ to choose. **↵** loads a text or rich item into the editor as a new session (formatting preserved for the Rich → Plain Text transform); since an image can't be edited yet, ↵ on an image item puts it straight back on the clipboard instead. **⌘↵** puts any item back on the clipboard and dismisses the panel; **⌘⌫** forgets the selected item; Esc closes the overlay.

Copying the same thing again moves it back to the top of the list rather than adding a duplicate, and keeps crediting the app that originally put it on the clipboard — reusing an item from history doesn't relabel it as coming from Pastefix. Items that password managers and similar tools mark as concealed, transient, or auto-generated are never recorded, including a few legacy marker conventions older apps still use.

History lives in `~/Library/Application Support/Pastefix/history/`, readable only by your user account. **Settings → General** has a History section to turn capture off, change how many items are kept, or clear everything; **Settings → Shortcut** rebinds ⌘⇧V. Note that ⌘⇧V is also "Paste and Match Style" in some apps — that conflict is a deliberate tradeoff for the more memorable default, and the hotkey is rebindable if it collides with something you use.

## Settings (Plan 2b)

Pastefix includes a Settings window (⌘, or "Settings…" in the menu) with three tabs:

- **General:** Configure wrap width (default 400 columns), toggle auto-hide-on-blur (dismisses the panel when focus leaves), choose a custom folder for user scripts (default `~/.config/pastefix/scripts/`), and a **History** section (remember-history toggle, item-count stepper, Clear History).
- **Shortcut:** Rebind the global hotkey (default ⌘⇧C) and the history hotkey (default ⌘⇧V), each using an interactive keyboard recorder.
- **Transforms:** Enable/disable individual transforms and drag to reorder them in the palette.

All settings persist via `UserDefaults`. User scripts are watched for changes; editing a script under `~/.config/pastefix/scripts/` updates the palette instantly without relaunch.

### Updates (Plan 2c)

Pastefix checks for updates once a day via [Sparkle](https://sparkle-project.org) and asks before installing anything. **Check for Updates…** in the menu bar runs a check on demand; Settings → General has an **Automatically check for updates** toggle, a **Check Now** button, and the installed version. Updates are EdDSA-signed and Developer-ID-verified; the feed is `https://bnaylor.github.io/pastefix/appcast.xml`. Maintainers: see [docs/RELEASING.md](docs/RELEASING.md).

## Overview

The engine provides:

- **Twenty-four built-in native transforms** written in Swift, fast and dependency-free
- **User scripts** discovered from `~/.config/pastefix/scripts/`, with automatic engine selection (shell or JavaScript) by file extension
- **Unified error handling** via typed `TransformError`; all transforms run off the main thread with configurable timeouts
- **Script metadata** via magic comments (name, enabled flag, execution order)
- **Filesystem watching** with debouncing for dynamic script discovery
- **Content detection** — the panel recognises URLs, JSON, colour literals, JWTs, Base64, percent-encoding and HTML entities, and lists the transforms that apply to them first

## Built-in Transforms

Each is a zero-configuration `Transformer` conforming to the protocol:

- **Rich → Plain Text:** Extracts plain text from rich RTFD data (requires original clipboard rich content; others work on the text buffer).
- **Transliterate to ASCII:** Converts smart punctuation, diacritics, and non-ASCII characters to ASCII equivalents (e.g., é → e, "curly quotes" → straight quotes, emoji dropped).
- **Wrap & Reflow:** Rewraps text to a configurable width (default 400 columns), respecting paragraph breaks.
- **Whitespace Cleanup:** Trims leading/trailing spaces and tabs from each line; collapses repeated blank lines.
- **Clean URL Tracking:** Removes tracking parameters (`utm_*`, `fbclid`, `gclid`, `si`, `mc_cid`, … ) from every URL in the text; other parameters, fragments, and surrounding text are untouched. HTML-escaped `&amp;` query separators (as found in links copied from email or HTML source) are normalised to `&` before stripping, which counts as a change on its own.
- **URL → Markdown Link:** Replaces each URL with `[Page Title](url)`. The title is fetched over the network with a 3-second timeout and a 256 KB cap; if that fails the link text is `host/path`. URLs already inside Markdown links are skipped. Up to 16 unique URLs per apply are fetched; any beyond that fall back to `host/path` without a network call. The link target always includes a scheme, so `www.example.com` becomes `[…](http://www.example.com)`. Titles are always fetched over `https`, even for an `http://` link (App Transport Security blocks cleartext, so a plain-`http` fetch could only ever fail) — the link target keeps the scheme the text had. Requests carry a `Pastefix` User-Agent and no cookies, and these are never contacted: loopback, link-local, private (RFC 1918 and CGNAT), multicast and reserved IPv4 ranges — including legacy numeric spellings such as `2130706433`, `0x7f.0.0.1` and `127.1` — their IPv6 equivalents (including IPv4-mapped addresses), and `localhost`, `*.local` and `*.localhost` names; redirects to any of those are refused. Hostnames are not resolved before fetching. Links to a blocked host just get the `host/path` fallback.
- **camelCase / snake_case / kebab-case / CONSTANT_CASE:** Rewrites each line as one identifier phrase. Splits on separators and camel boundaries (`HTTPServerError` → `http_server_error`), keeps digits with their word (`utf8Decoder`), preserves indentation and non-ASCII letters.

### Data

- **JSON Prettify:** Reformats JSON with 2-space indentation. Output keys are always sorted, so runs are deterministic.
- **JSON Minify:** Reformats JSON onto a single line, no whitespace. Output keys are always sorted.
- **Escape as JSON String:** Wraps the entire buffer as one JSON string literal (quotes, backslashes, control characters escaped); never fails.
- **Base64 Encode:** Encodes the buffer as standard Base64 text.
- **Base64 Decode:** Decodes Base64 to text only — never binary. Tolerates whitespace, missing padding, and the URL-safe alphabet; fails if the result isn't valid UTF-8.
- **URL Encode:** Percent-encodes everything except the RFC 3986 unreserved characters (`A–Z a–z 0–9 - . _ ~`); a space becomes `%20`.
- **URL Decode:** Reverses percent-encoding; leaves `+` alone (no form-encoding assumption); rejects malformed `%` sequences.
- **HTML Encode:** Escapes `& < > " '` to `&amp; &lt; &gt; &quot; &#39;`.
- **HTML Decode:** Decodes named, decimal, and hex character references, including the HTML4 Latin-1 named entities (`&eacute;`, `&nbsp;`, …); unknown entities are left verbatim.
- **Decode JWT:** Shows a JWT's header and payload as pretty JSON. Never verifies the signature. `exp`/`iat`/`nbf`, when present as plausible numbers, are printed as UTC comment lines below the JSON, with `exp` also noting `(expired)`/`(valid)`.

### Colors

All four accept `#hex`, `rgb()`/`rgba()`, and `hsl()`/`hsla()` input, either comma-separated or CSS4 space/slash syntax, and rewrite it in a different notation:

- **Color → CSS Hex:** `#rrggbb`, or `#rrggbbaa` when there's an alpha channel.
- **Color → CSS rgb():** `rgb(r g b)`, or `rgb(r g b / a)` with an alpha channel.
- **Color → CSS hsl():** `hsl(h s% l%)`, or `hsl(h s% l% / a)` with an alpha channel.
- **Color → SwiftUI Color:** `Color(red:green:blue:opacity:)` with 3-decimal literals.

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
- **Keys:** `name` (display name), `enabled` (true/false; default true), `order` (integer execution order; default 1000 for scripts), `kinds` (comma-separated list of `url`, `json`, `color`, `jwt`, `base64`, `percentEncoded`, `htmlEntities`, matched case-insensitively — `percentencoded` and `PercentEncoded` both work; a script with `kinds` is listed first in the ⌘K palette when that content is detected; unknown names ignored), `category` (free text, trimmed; groups the script under this heading in the sidebar; default `Scripts` when omitted; a custom category appears in the sidebar alphabetically after the built-in categories below)
- **Built-in order:** Rich→Plain (10), Transliterate (20), Wrap (30), Whitespace (40), Clean URL Tracking (50), URL → Markdown Link (60), camelCase (70), snake_case (71), kebab-case (72), CONSTANT_CASE (73), JSON Prettify (80), JSON Minify (81), Escape as JSON String (82), Base64 Encode (90), Base64 Decode (91), URL Encode (92), URL Decode (93), HTML Encode (94), HTML Decode (95), Decode JWT (96), Color → CSS Hex (100), Color → CSS rgb() (101), Color → CSS hsl() (102), Color → SwiftUI Color (103); user scripts at order 1000+ appear after built-ins unless explicitly reordered
- **Malformed lines:** ignored silently

**Built-in categories** (sidebar order):

| Category | Built-in transforms |
|---|---|
| Layout | Wrap & Reflow, Whitespace Cleanup |
| Characters | Rich → Plain Text, Transliterate to ASCII |
| URLs | Clean URL Tracking, URL → Markdown Link |
| Case | camelCase, snake_case, kebab-case, CONSTANT_CASE |
| Data | JSON Prettify, JSON Minify, Escape as JSON String, Base64 Encode/Decode, URL Encode/Decode, HTML Encode/Decode, Decode JWT |
| Colors | Color → CSS Hex, Color → CSS rgb(), Color → CSS hsl(), Color → SwiftUI Color |

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
