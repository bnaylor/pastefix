---
type: spec
status: approved
id: 2026-09-20-pastefix-v2-quick-actions
title: Pastefix v2 — Per-type Quick Actions (Plan 5)
description: Five new content kinds (color, jwt, base64, percentEncoded, htmlEntities), fourteen new built-in transforms across two new categories (Data, Colors), a ColorLiteral value type with a swatch in the action bar, and a TransformError.invalidInput case for decode failures.
tags: [pastefix, macos, swift, transforms, detection]
timestamp: 2026-09-20T23:59:00Z
---

# Pastefix v2 — Per-type Quick Actions (Plan 5)

Source: [issue #11](https://github.com/bnaylor/pastefix/issues/11), from the
original requirements §1 "Smart Content Detection & Contextual Quick-Actions".
Plan 3 shipped the substrate (`ContentDetector`, `applicableKinds`,
applicable-first ordering); Plan 4 made the palette searchable and categorised.
This plan adds the consumers.

## Scope

**In scope:**

- `ContentKind` gains `color`, `jwt`, `base64`, `percentEncoded`,
  `htmlEntities`, with detectors in `ContentDetector`.
- Fourteen built-in transforms in two new categories, **Data** (orders 80–96)
  and **Colors** (100–103). See the table below.
- `ColorLiteral` in `PastefixCore`: parses every accepted colour form and
  formats every output form; also drives the swatch.
- `TransformError.invalidInput(String)` for decode failures.
- A colour swatch beside the "Detected: Color" badge in the action bar
  (`AppModel.detectedColor`).
- Tests for all of the above; README / AGENTS.md currency.

**Explicitly out of scope:**

- `code`, `shell`, `sql` kinds (nothing consumes them yet).
- Colour picker, palette editing, or colour-space conversion beyond sRGB.
- JWT signature verification (explicitly never).
- Encoding/decoding of binary payloads into the editor.
- Any Settings changes.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Whole-buffer detection for `color`, `jwt`, `base64` | Only when the trimmed buffer *is* the literal | These actions rewrite the whole buffer; offering "decode Base64" on prose that merely contains a token would mangle it. `percentEncoded`/`htmlEntities` are presence checks because their decoders operate in place on prose safely. |
| Base64 must decode to UTF-8 text | Otherwise the kind is not detected | The editor is a text buffer; decoded binary would be corrupted on Save. Encode is always available; Decode only when it is safe. |
| `base64` excluded when `jwt` matches | A JWT's segments are base64url and would otherwise light both | One badge, one obvious action. |
| Decode failures raise `TransformError.invalidInput(String)` | New case, existing cases untouched | Critical Invariant 2 forbids renaming/repurposing cases, not adding one. `scriptFailed` is for scripts; misusing it would lie in the banner. |
| Encoders always applicable (`applicableKinds = nil`); decoders promoted by kind | — | Encoding is a choice the user makes about any text; decoding is only meaningful when the input is encoded. |
| JWT output is pretty JSON `{ "header": …, "payload": … }` plus an `exp` line | Readable, copy-pasteable, and honest | The trailing line `// exp: 2026-10-01T12:00:00Z (expired|valid)` and `// signature not verified` are comments outside the JSON so the JSON stays valid if the user deletes them. |
| One `ColorLiteral` type, sRGB, components 0…1, alpha 0…1 | Parse: `#RGB #RGBA #RRGGBB #RRGGBBAA`, `rgb()/rgba()` with 0–255 ints or percentages and alpha 0–1 or %, `hsl()/hsla()` with deg and %; CSS4 space/slash syntax accepted | Covers what people paste from CSS, design tools, and code. No named colours (`rebeccapurple`) in v1 — they would need a table and rarely need conversion. |
| Colour output forms | CSS hex (`#rrggbb`, `#rrggbbaa` only if alpha < 1), CSS `rgb(r g b / a)` modern syntax, `hsl(h s% l% / a)`, SwiftUI `Color(red:green:blue:opacity:)` with 3-decimal literals | Matches the requirements' "CSS, HSL, or Swift Color snippet". |
| Swatch | 14×14 rounded rect in the action bar, only when `color` is detected | The one UI addition the issue calls for; no picker. |
| Categories | `TransformCategory.data = "Data"`, `.colors = "Colors"`, appended to `builtinOrder` | Sidebar/palette grouping falls out of Plan 4 for free. |

## Architecture

### `PastefixCore`

**`Detection/ContentKind.swift`** — add cases and display names:

| case | displayName |
|---|---|
| `color` | Color |
| `jwt` | JWT |
| `base64` | Base64 |
| `percentEncoded` | Percent-encoded |
| `htmlEntities` | HTML entities |

**`Detection/ContentDetector.swift`** — rules, evaluated on the trimmed buffer `t`
(existing `url`/`json` unchanged; 1 MB guard unchanged):

- `color`: `ColorLiteral.parse(t) != nil`.
- `jwt`: `JWTDecoder.split(t)` succeeds — exactly two dots, three non-empty
  base64url segments (the third may be empty for `alg: none`), and the first
  decodes to a JSON object containing `"alg"`.
- `base64`: not `jwt`; `Base64Codec.looksLikeBase64(t)`. *(Amended in review —
  this paragraph now describes what shipped rather than what was planned; see
  `e2b0807`.)* That is ≥ 16 characters after whitespace is filtered out, then
  `Base64Codec.decodeText`: whitespace filtered, `-`/`_` folded to `+`/`/`, any
  trailing `=` stripped and re-padded to a multiple of 4, the remaining
  characters validated as ASCII alphanumerics plus `+` and `/` (so the
  alphabet is checked explicitly rather than delegated), decoded with
  `Data(base64Encoded:)` **without** `.ignoreUnknownCharacters` — the option
  would silently drop junk and make almost any prose "decode" — and the bytes
  required to be NUL-free valid UTF-8. `looksLikeBase64` then additionally
  requires the decoded text to be printable: tab/newline/CR are allowed, but no
  other C0 control, no DEL, and no C1 control (0x80–0x9F).
- `percentEncoded`: `t` contains the regex `%[0-9A-Fa-f]{2}`.
- `htmlEntities`: `t` contains `&(#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]{1,31});`.

**`Native/ColorLiteral.swift`** (new)

```swift
public struct ColorLiteral: Equatable, Sendable {
    public var red, green, blue, alpha: Double   // 0…1
    public static func parse(_ text: String) -> ColorLiteral?
    public var cssHex: String        // "#rrggbb" or "#rrggbbaa" when alpha < 1
    public var cssRGB: String        // "rgb(255 0 128)" / "rgb(255 0 128 / 0.5)"
    public var cssHSL: String        // "hsl(330 100% 50%)" / "hsl(330 100% 50% / 0.5)"
    public var swiftUI: String       // "Color(red: 1.000, green: 0.000, blue: 0.502)" (+ ", opacity: 0.500" when alpha < 1)
    public var hsl: (h: Double, s: Double, l: Double)
}
```

Parsing is case-insensitive, tolerates surrounding whitespace, and accepts
both legacy comma syntax and CSS4 space/slash syntax. Hue is normalised into
`0..<360`; percentages clamp to 0…100; channels clamp to 0…255. Rounding:
hex uses `Int((c * 255).rounded())`; HSL prints integer degrees and integer
percentages; alpha prints up to 3 decimals with trailing zeros trimmed
(`0.5`, `0.333`).

*Amended in review (`15a2b7e`):* `parseHex` rejects hex digits that satisfy
`Character.isHexDigit` but are not ASCII (e.g. fullwidth digits), since
`UInt8(_:radix:)` rejects them and would otherwise force-unwrap to a crash.
Numeric parsing (`channel`, `hue`, alpha, percent) rejects non-finite `Double`
values (`nan`, `inf`, `-inf`) and hex-float tokens (anything containing `x`,
e.g. `0x1p3`) that `Double.init(_:)` would otherwise accept — both survive
naive `min`/`max` clamping. Separately, `hasAlpha` gates on the *rounded*
8-bit alpha (`Int((alpha * 255).rounded()) < 255`), not the raw `Double`, so
an alpha of `0.9999` (rounds to 255) prints with no alpha channel at all.

**`Native/JSONActions.swift`** (new) — three transforms:

| id | name | order | kinds | behaviour |
|---|---|---|---|---|
| `builtin.json.pretty` | JSON Prettify | 80 | `[json]` | `JSONSerialization` with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` (its native 2-space indent, used as is). Invalid JSON → `invalidInput("Not valid JSON: <first line of the error>")`. |
| `builtin.json.minify` | JSON Minify | 81 | `[json]` | `[.sortedKeys, .withoutEscapingSlashes]`, no pretty flag. Same error. |
| `builtin.json.escape` | Escape as JSON String | 82 | nil | Wraps the entire buffer as one JSON string literal (quotes, backslashes, control chars, newlines escaped); never fails. |

`.sortedKeys` is a deliberate choice: deterministic output. Note it in README.

*Amended in review (`e2b0807`):* `JSONReformat.render` also guards non-finite
numbers. `JSONSerialization.data(withJSONObject:)` raises an Objective-C
exception rather than throwing a Swift error — uncatchable by `try` — and a
value like `-1e400` parses to `-inf` and would abort the process on write.
`render` checks `isValidJSONObject` first (allowing the safe scalar fragments
`String`/`NSNull`/finite `NSNumber`) and throws
`invalidInput("Not valid JSON: number out of range")` instead of writing.

**`Native/Encoders.swift`** (new) — one `enum Codec { case base64, url, html }`
and two structs `Encode(codec:)` / `Decode(codec:)`, registered as six
transforms:

| id | name | order | kinds |
|---|---|---|---|
| `builtin.base64.encode` | Base64 Encode | 90 | nil |
| `builtin.base64.decode` | Base64 Decode | 91 | `[base64]` |
| `builtin.url.encode` | URL Encode | 92 | nil |
| `builtin.url.decode` | URL Decode | 93 | `[percentEncoded]` |
| `builtin.html.encode` | HTML Encode | 94 | nil |
| `builtin.html.decode` | HTML Decode | 95 | `[htmlEntities]` |

- Base64: encode UTF-8 with standard alphabet and padding, no line breaks.
  Decode strips ASCII whitespace, accepts standard and url-safe alphabets,
  pads; failure or non-UTF-8 → `invalidInput("Not valid Base64 text")`.
- URL: encode with `addingPercentEncoding(withAllowedCharacters:)` using the
  RFC 3986 unreserved set (`A–Z a–z 0–9 - . _ ~`) so `&`, `=`, `/`, space are
  all encoded (query-component semantics; space → `%20`, not `+`). Decode via
  `removingPercentEncoding`; `+` is left alone (predictable; form-encoding's
  `+`-for-space is not assumed). A `%(?![0-9A-Fa-f]{2})` pre-check rejects a `%`
  that does not introduce two hex digits before decoding — `removingPercentEncoding`
  returns the string unchanged for some malformed inputs rather than nil, so the
  nil check alone would let `100%` through as a silent no-op. Either path →
  `invalidInput("Malformed percent-encoding")`.
- HTML: numeric references to C0 controls other than tab/LF/CR (`&#0;`,
  `&#x1F;`) are **left verbatim** rather than decoded — splicing a NUL into the
  working buffer truncates the value for anything downstream that speaks C
  strings, and the rest are invisible rather than useful.
  Encode `& < > " '` → `&amp; &lt; &gt; &quot; &#39;`. Decode reuses
  `URLSessionTitleFetcher.decodeEntities` (moved to a shared internal
  `HTMLEntities.decode` in `Detection/` or `Native/`, with the existing named
  table extended to the HTML4 Latin-1 set: `nbsp iexcl cent pound … yuml`
  plus `apos`). Unknown entities are left verbatim; decode never fails.

**`Native/JWTDecode.swift`** (new) — `builtin.jwt.decode`, "Decode JWT",
order 96, `[jwt]`. `JWTDecoder.split(_:) -> (header: Data, payload: Data)?`
does base64url decoding with padding repair. Output:

```
{
  "header": { … },
  "payload": { … }
}
// exp: 2026-10-01T12:00:00Z (expired)
// signature not verified
```

`exp`/`iat`/`nbf` are echoed as ISO 8601 in comment lines when present as
numbers; the `(expired)`/`(valid)` suffix compares `exp` with the current date.
A payload that is not a JSON object still decodes (arrays/scalars are printed
as-is). Failure to decode either segment → `invalidInput("Not a decodable JWT")`.

*Amended in review (`e2b0807`):* a timestamp claim is skipped (no comment
line) when its JSON value is a boolean or falls outside `0...32_503_680_000`
epoch seconds (roughly year 1970–3000) — `NSNumber` bridges `true`/`false` as
1/0, and an absurd magnitude is not a meaningful date to render.

**`Native/ColorConvert.swift`** (new) — one struct `ColorConvert(style:)`:

| id | name | order | style output |
|---|---|---|---|
| `builtin.color.hex` | Color → CSS Hex | 100 | `cssHex` |
| `builtin.color.rgb` | Color → CSS rgb() | 101 | `cssRGB` |
| `builtin.color.hsl` | Color → CSS hsl() | 102 | `cssHSL` |
| `builtin.color.swift` | Color → SwiftUI Color | 103 | `swiftUI` |

All `[color]`. Input that fails to parse → `invalidInput("Not a color literal")`.

**`Transformer.swift`** — `TransformError` gains `case invalidInput(String)`.
`TransformCategory` gains `data`, `colors`; `builtinOrder` becomes
`[layout, characters, urls, case, data, colors]`.

**`Discovery/TransformerRegistry.swift`** — register the fourteen entries at
the orders above. Critical Invariant 8's order list extends to `80–96` and
`100–103`.

### `PastefixAppCore`

`TransformCoordinator` already maps any `TransformError` to a banner message;
add a case for `invalidInput` so the banner shows the message verbatim
(check the existing `switch` — if it uses a default `String(describing:)`,
add the explicit case for a clean message).

### `Pastefix` app

- `AppModel.detectedColor: ColorLiteral?` — `document.detectedKinds.contains(.color) ? ColorLiteral.parse(document.working) : nil`.
- `PanelView.actionBar`: when `model.detectedColor` is non-nil, a
  `RoundedRectangle(cornerRadius: 3).fill(Color(red:green:blue:opacity:))`
  14×14 with a hairline secondary stroke, placed before the "Detected: …" text,
  `.accessibilityLabel("Detected color \(literal.cssHex)")` (US spelling, matching
  the transform names).
- `AppModel.detectedSummary` unchanged (the new display names flow through).

## Data flow

Summon with `#ff0080` → detector returns `[.color]` → action bar shows a
magenta swatch and "Detected: Color" → ⌘K lists the four Color transforms
first → ↵ on "Color → CSS hsl()" → `ColorConvert.apply` → buffer becomes
`hsl(330 100% 50%)` → still `[.color]`, swatch unchanged. Summon with a JWT →
`[.jwt]` → "Decode JWT" first → output is pretty JSON followed by trailing
`// exp: …` / `// signature not verified` comment lines. Summon with prose
containing `%20` → `[.percentEncoded]` → URL Decode promoted; applying it
decodes in place.

*Amended in review:* the JWT output is **not** re-detected as `[.json]`. The
`json` kind requires the trimmed buffer to parse outright
(`JSONSerialization.jsonObject`), and the trailing `//` comment lines are not
valid JSON, so parsing fails and JSON Prettify/Minify are never promoted for
a just-decoded JWT — the sentence above describing that promotion was wrong
and is corrected here.

## Error handling

- Every decoder and colour transform throws `TransformError.invalidInput` on
  bad input; `TransformCoordinator` keeps the prior text and shows the banner
  (Critical Invariant 2). Encoders, JSON Escape, and HTML Decode never fail.
- Detection never throws; base64 detection's decode is bounded by the 1 MB
  guard.
- `ColorLiteral.parse` returns nil rather than clamping garbage into a colour.

## Testing

`Tests/PastefixCoreTests/`:

- `ColorLiteralTests`: parse `#fff`, `#ffff`, `#FF0080`, `#ff008080`,
  `rgb(255, 0, 128)`, `rgb(255 0 128 / 0.5)`, `rgb(100%, 0%, 50%)`,
  `rgba(255,0,128,50%)`, `hsl(330, 100%, 50%)`, `hsl(-30 100% 50%)` (hue
  wrap → 330), `hsla(330deg 100% 50% / .25)`; reject `#ggg`, `#12345`,
  `rgb(1,2)`, `red`, `#fff extra`; round-trips hex→rgb→hsl→hex for a table of
  colours; formatting of each output form incl. alpha trimming (`0.5`, `0.333`,
  `1` omitted).
- `JSONActionsTests`: pretty/minify on nested objects (sorted keys, slashes not
  escaped, unicode preserved), invalid JSON → `invalidInput`, escape of quotes,
  backslashes, newlines, tabs, control chars, emoji; metadata for the three.
- `EncodersTests`: base64 round trip incl. unicode; decode with newlines and
  missing padding; url-safe alphabet; invalid → `invalidInput`; binary (a
  decoded NUL) → `invalidInput`; URL encode of `a b&c=d/é` → `a%20b%26c%3Dd%2F%C3%A9`;
  URL decode incl. `%E2%80%94`; malformed `%ZZ` → `invalidInput`; HTML encode of
  `<a href="x">Tom & Jerry's</a>`; HTML decode of named, numeric, hex, Latin-1
  names (`&eacute;`), unknown left verbatim, `&amp;lt;` → `&lt;`; metadata for
  all six.
- `JWTDecodeTests`: a fixed HS256 token (header/payload known) → exact output
  incl. the `exp` comment and `(expired)`; token without `exp` → no exp line;
  `alg: none` with empty signature; malformed (two segments, bad base64) →
  `invalidInput`; never touches the signature.
- `ContentDetectorTests` additions: each new kind's positive; negatives:
  `#fff` in prose (not `color`), a 15-char base64, base64 that decodes to
  binary, a JWT not also flagged `base64`, prose with `%` but no hex pair,
  `&` without `;`; and that JWT decode output is not re-detected as JSON (the
  trailing comment lines break strict JSON).
- `TransformerRegistryTests`: ids/orders/categories for the fourteen;
  `builtinOrder` has six entries.
- Every new transform's `metadata()` test asserts id, name, category, kinds.

`Tests/PastefixAppCoreTests/`: `TransformCoordinatorTests` — an `invalidInput`
thrower leaves the document unchanged and yields the message.

Manual: swatch appears for `#ff0080` and `hsl(120 50% 50%)`, disappears for
prose; Decode JWT on a real token; URL Decode in prose; Base64 Decode error
banner on garbage that still detects as base64 (won't happen by construction —
verify a 16-char valid-alphabet non-UTF-8 string is *not* detected).

## Documentation

- `README.md`: the fourteen transforms in "Built-in Transforms" grouped under
  Data and Colors; the five new kinds in the content-detection paragraph;
  note JSON output uses sorted keys; note JWT signatures are never verified.
- `AGENTS.md`: layout entries (`ColorLiteral.swift`, `JSONActions.swift`,
  `Encoders.swift`, `JWTDecode.swift`, `ColorConvert.swift`, shared HTML
  entities); Critical Invariant 2 lists `invalidInput(String)`; Invariant 8's
  order list; status row for Plan 5.

## Project layout delta

```
Sources/PastefixCore/
  Transformer.swift                 # + TransformError.invalidInput, TransformCategory.data/.colors
  Detection/ContentKind.swift       # + color, jwt, base64, percentEncoded, htmlEntities
  Detection/ContentDetector.swift   # + five detectors
  Detection/HTMLEntities.swift      # shared decode table (moved out of MarkdownLink)
  Native/ColorLiteral.swift         # parse + format
  Native/ColorConvert.swift         # builtin.color.{hex,rgb,hsl,swift} 100–103
  Native/JSONActions.swift          # builtin.json.{pretty,minify,escape} 80–82
  Native/Encoders.swift             # builtin.{base64,url,html}.{encode,decode} 90–95
  Native/JWTDecode.swift            # builtin.jwt.decode 96
Pastefix/Pastefix/
  AppModel.swift                    # + detectedColor
  PanelView.swift                   # + swatch in the action bar
```

## Open questions / future increments

- Named CSS colours and colour-space conversions (P3, OKLCH) if anyone asks.
- `code` / `shell` / `sql` kinds with their own actions.
- A colour picker popover on the swatch.
