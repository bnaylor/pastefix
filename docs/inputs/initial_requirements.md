---
type: proposal
status: draft
id: 2026-08-11-initial-pastefix-requirements
title: Initial Pastefix Requirements
description: Describe what I want Pastefix v2 to be initially.
tags: [pastefix, project, macos, clipboard]
timestamp: 2026-08-11T20:15:17Z
---

# Pastefix v2 Initial Requirements

## Background

Pastefix was a macos application I wrote *by hand* back in the old days when we did that sort of thing.
It was written in Objective C, and was a menubar application with a global hotkey whose entire purpose
was to make it easier and safer to paste text content from various sources into IRC terminal windows.

Key features:
- global hotkey summons the window from anywhere
- lets you see and edit the content before pasting
- auto-wrap to fit terminal column widths w/newlines inserted
- the equivalent of vim's gq{ (reflow text w/new wrap width)
- strip special/unicode characters which printed weirdly in most peoples' terminals then
- convert rich text to plain text 
- other auto text-formatting ideas (not sure how many got implemented)
- click "save" to replace clipboard contents with edited version
- click "cancel" to keep original contents

The source for some version of this (I think it's backlevel from the final version) is available
still in ~/Source/Pastefix - and actually the README.md there does a decent job explaining it
and mentions some things I forgot above.  Rather than flesh this out here, just read that file
and the TODO file as well.  Looks like there's a legit 2007 version in ~/Source/pastefix-save/ as well.

> **Editor's note (2026-09-18):** both of those trees were machine-local. The files
> referenced above are now vendored under [`legacy/`](legacy/) — see
> [`legacy/README.md`](legacy/README.md) for the map. `~/src/ishare` (the Zipline
> reference, cited under "Soon") was deliberately *not* vendored; that work stays
> on the original machine.

Oh and https://scromp.net/Pastefix/ still exists!

# Goals

I'd like to create a modern v2 version of this with the following attributes.

## First
- Swift instead of ObjC
- Modernized UI
- Most of the features of the old one, but
- Less focus on autoconverting to plain text - we'll have different flows for different types of content.
- The user-defined pipeline/workflow idea in the TODO in the original repo is interesting, though I
  don't know that we should hook python up to it.  Pretty sure that's where things fell over in 2019.
  - JavaScriptCore and/or Shell script custom transformer pipeline (`~/.pastefix/scripts/`)
- URL tracking-parameter stripping (`utm_*`, `fbclid`, etc.)
- Strip leading spaces
- Auto-detect content types
- Sensitive app history exclusion (password managers, etc)

## Soon
- Quick case conversions (camelCase, snake_case, kebab-case)
- Multiple clipboard items support (then I can delete CopyClip)
- Post to Zipline (then I can delete iShare - ~/src/ishare for reference on zipline details)
- Markdown preview
- Markdown <> rich text conversion
- Automatic updates
- Fuzzy search clipboard history
- Pinned snippets
- Zipline upload controls
- Secret / API key detector before Zipline paste or sharing
- URL to Markdown link conversion (`[Title](URL)`)


## Later
- Support for images - viewing initially, then trivial editing
- Native OCR
- Image sanitization
- Format conversion
- Expose pastefix functionality to Shortcuts for automation


# More detailed descriptions of some of the above

### 1. Smart Content Detection & Contextual Quick-Actions

• Auto-Detect Content Types: Automatically recognize content in the clipboard (JSON,
SQL, URLs, Colors, JWTs, Code, Shell commands) and show target action buttons:
    • JSON: 1-click Prettify / Minify / Escape quotes.
    • URLs: Clean tracking parameters (utm_*, fbclid, si=) automatically, or format
    into Markdown [Page Title](URL) via instant background title fetching.
    • Hex / RGB Colors: Show color swatch preview and copy as CSS, HSL, or Swift Color
    snippet.
    • Code Cases: Quick case conversion toggles (camelCase, snake_case, kebab-case,
    CONSTANT_CASE).
    • Data Encoders: 1-click Base64 / URL / HTML entity encode/decode, and JWT token
    decoding.


### 2. Modern Pipeline & Lightweight Scripting

• JavaScript / Shell-based Transformers: Instead of Python binding overhead, use
Apple's native JavaScriptCore or shell command pipes (/bin/sh or stdin/stdout scripts
in ~/.config/pastefix/scripts/).
• Regex Presets: User-defined regex find & replace rules saved as quick action buttons
or hotkeys.
• PII & Secret Sanitizer (Safety Guard): Option to detect AWS keys, OpenAI tokens (sk-
...), private keys, or passwords in text before posting to Zipline or pasting into
IRC/chat.

### 3. Native OCR & Enhanced Image Handling

• Apple Vision OCR: Instantly extract text from copied screenshots or images using
Apple’s native Vision framework.
• Image Sanitization: Strip EXIF metadata (GPS location, device info) from images
before saving or uploading.
• Format Conversion & QR Codes: 1-click PNG/JPEG/WebP conversion, image compression,
and QR code generation/scanning.

### 4. Advanced Multi-Clipboard & Privacy Control

• Fuzzy Search Overlay: Spotlight/Raycast-style quick window (Cmd+Shift+V) to fuzzy
search clipboard history.
• Pinned Snippets & Expansion: Pin frequently used text blocks, shell commands, or
boilerplate snippets with quick keybindings or text expansion triggers.
• Sensitive App Exclusions: Blacklist password managers (e.g., 1Password, Bitwarden,
Keychain) or apps with hidden content flags (NSPasteboard.Type.concealed) from
entering clipboard history.

### 5. Zipline / Sharing Upgrades (iShare Replacement)

• One-Step Quick Upload: Global shortcut (Cmd+Shift+U) to upload whatever is in the
pasteboard (image, code snippet, plain text) to Zipline and replace clipboard with the
short URL + notification.
• Upload Controls: Quick dropdown popover for Zipline upload expiration (1 hour, 1 day,
7 days, burn-on-read) and custom syntax highlighting selection.

### 6. macOS Integration

• Shortcuts App & AppleScript Support: Expose Pastefix workflows to the macOS
Shortcuts app so automations can run text transformations.
• Compact / Popover UX: Toggle between a minimal menubar popover overlay and a
floating panel.

