# PastefixCore

PastefixCore is a macOS clipboard transform engine that unifies native Swift transforms, shell scripts, and JavaScript functions under a single `Transformer` protocol. It powers the transform pipeline of Pastefix v2, a clipboard utility that applies transformations on demand.

> **Note:** This package documents the transform engine. The Pastefix v2 app UI (menu bar, editor integration, settings) is a forthcoming separate layer.

## Overview

The engine provides:

- **Four built-in native transforms** written in Swift, fast and dependency-free
- **User scripts** discovered from `~/.config/pastefix/scripts/`, with automatic engine selection (shell or JavaScript) by file extension
- **Unified error handling** via typed `TransformError`; all transforms run off the main thread with configurable timeouts
- **Script metadata** via magic comments (name, enabled flag, execution order)
- **Filesystem watching** with debouncing for dynamic script discovery

## Built-in Transforms

Each is a zero-configuration `Transformer` conforming to the protocol:

- **Rich → Plain Text:** Extracts plain text from rich RTFD data (requires original clipboard rich content; others work on the text buffer).
- **Transliterate to ASCII:** Converts smart punctuation, diacritics, and non-ASCII characters to ASCII equivalents (e.g., é → e, "curly quotes" → straight quotes, emoji dropped).
- **Wrap & Reflow:** Rewraps text to a configurable width (default 400 columns), respecting paragraph breaks.
- **Whitespace Cleanup:** Trims leading/trailing spaces and tabs from each line; collapses repeated blank lines.

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
- **Timeout:** configured per registry (default 3 seconds); on timeout, the process is terminated cleanly (SIGTERM)

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
- **Timeout caveat:** JavaScriptCore cannot be interrupted. If a JS script runs past the timeout, the best-effort strategy is to abandon the continuation and let the thread finish on process exit. Shell scripts, by contrast, are killed cleanly via SIGTERM.

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

- **Comment syntax:** lines are tolerant of comment markers (`#`, `//`, `*`, `/*`); the parser strips leading whitespace and common comment characters
- **Keys:** `name` (display name), `enabled` (true/false; default true), `order` (integer execution order; default 1000 for scripts)
- **Built-in order:** Rich→Plain (10), Transliterate (20), Wrap (30), Whitespace (40); user scripts at order 1000+ appear after built-ins unless explicitly reordered
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
    wrapWidth: 80,
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

### Shell: Word Frequency

```bash
#!/bin/bash
# pastefix: name = Word Frequency, order = 900
# List words sorted by frequency

tr ' ' '\n' | sort | uniq -c | sort -rn
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
