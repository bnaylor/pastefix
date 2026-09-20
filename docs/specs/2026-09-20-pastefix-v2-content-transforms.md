---
type: spec
status: approved
id: 2026-09-20-pastefix-v2-content-transforms
title: Pastefix v2 — Content Transforms & Detection (Plan 3)
description: Five new built-in transforms (URL tracking cleanup, URL → Markdown link, four case conversions), a pure content detector (URL, JSON), transformer opt-in to content kinds, and a palette that surfaces applicable transforms first.
tags: [pastefix, macos, swift, transforms, detection]
timestamp: 2026-09-20T18:00:00Z
---

# Pastefix v2 — Content Transforms & Detection (Plan 3)

## Scope

Closes most of the requirements' **First** tier that the foundation spec left
as "future pipeline transformers": URL tracking-parameter stripping and content
auto-detection. Pulls in the two **Soon** items that are the same shape and
cost almost nothing extra: quick case conversions and URL → Markdown link.
"Strip leading spaces" is already delivered by `WhitespaceCleanup` and is not
repeated here.

**In scope:**

- `ContentKind` + `ContentDetector` in `PastefixCore` (kinds: `url`, `json`).
- `Transformer.applicableKinds` (optional, default nil = always applicable) and
  a `kinds` magic-comment key for user scripts.
- Five built-in transforms: Clean URL Tracking, URL → Markdown Link,
  camelCase, snake_case, kebab-case, CONSTANT_CASE (the last four are one
  parameterised struct).
- `PasteDocument.detectedKinds`, a pure `PaletteOrdering` in
  `PastefixAppCore`, and a "Detected: …" badge beside the palette.
- Fixture-driven tests for all of the above; README and AGENTS.md currency.

**Explicitly out of scope** (later increments):

- Per-type quick-action panels (JSON prettify/minify/escape, colour swatches
  and format conversion, Base64/URL/HTML encode–decode, JWT decode). This
  spec's detector and `applicableKinds` are the substrate they will use.
- Additional kinds (`code`, `shell`, `sql`, `color`, `jwt`). The enum is
  extensible; nothing consumes them yet, so they don't ship.
- Regex presets, secret sanitiser, clipboard history, Zipline.
- Any change to the Settings window.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Detection model | Pure `ContentDetector.detect(_:) -> Set<ContentKind>` in the engine; transforms declare `applicableKinds`; the app orders the palette | One tested place for heuristics; scripts can participate via a header key; the palette can explain itself with a badge. A per-transform predicate scatters logic and gives nothing to badge; a separate actions layer is the tripled scope we declined. |
| Kinds shipped | `url`, `json` | Both have deterministic detectors. `url` has two consumers in this plan; `json` ships as a badge-only kind because it is cheap and the quick-actions plan needs it first. |
| URL cleaning scope | Every URL in the buffer, not just a lone URL | Pasting prose with links is the common case; a single-URL-only cleaner would silently do nothing on it. |
| Tracking parameter list | Built-in: exact names `fbclid gclid dclid gbraid wbraid igshid si mc_cid mc_eid ref ref_src _hsenc _hsmi yclid vero_id mkt_tok oly_anon_id oly_enc_id`, plus any name with prefix `utm_` | Covers the requirements' examples and the usual offenders. Not user-configurable in this increment; a script can do bespoke cleaning. |
| Markdown link title | Fetched over the network, 3 s timeout, 256 KB cap, fallback `host/path` | The user chose fetching. Bounded so a slow site can't exceed the app's 3 s transform gate by much; fallback keeps the transform total (never fails on network error). |
| Network isolation | `TitleFetcher` protocol; default `URLSessionTitleFetcher`; tests inject a stub | First network access in the engine. Tests stay offline and deterministic. |
| Case conversion UX | One transform per case; one `CaseConvert(style:)` struct behind four ids | Consistent with the palette model; each individually enable/reorder-able. |
| Case conversion unit | Each **line** is one identifier phrase; line breaks preserved | "Quick case conversion of a copied identifier or phrase" is the use; multi-line input keeps its structure. |
| Palette ordering | Partition the user-ordered list: transforms whose `applicableKinds` intersect the detected kinds come first; everything else keeps its order | Additive on top of Plan 2b's per-transform order; nothing disappears, nothing reorders within a partition. |
| Size guard | Detection returns `[]` for buffers > 1 MB | JSON parsing and link detection on huge pastes would stall summon; the badge is a nicety. |

## Architecture

### `PastefixCore`

**`Detection/ContentKind.swift`** (new)

```swift
public enum ContentKind: String, CaseIterable, Sendable, Codable {
    case url
    case json
    /// Human-readable label for the badge: "URL", "JSON".
    public var displayName: String
}
```

**`Detection/ContentDetector.swift`** (new)

```swift
public enum ContentDetector {
    public static let maxBytes = 1_048_576
    public static func detect(_ text: String) -> Set<ContentKind>
}
```

- Returns `[]` if `text.utf8.count > maxBytes` or the trimmed text is empty.
- `url`: `NSDataDetector(types: .link)` finds at least one match whose URL
  scheme is `http` or `https`. (Bare `www.example.com` matches too; `mailto:`
  does not.)
- `json`: the trimmed text's first character is `{` or `[` **and**
  `JSONSerialization.jsonObject(with:options:[])` (fragments not allowed)
  succeeds. The first-character check avoids parsing every paste.

**`Transformer.swift`** — protocol gains one requirement with a default:

```swift
public protocol Transformer: Identifiable, Sendable {
    …
    /// Kinds this transform is meant for. `nil` = always applicable (the default).
    var applicableKinds: Set<ContentKind>? { get }
}
public extension Transformer { var applicableKinds: Set<ContentKind>? { nil } }
```

Existing native transforms, `ShellTransformer`, and `JSTransformer` compile
unchanged. The two script transformers *do* implement it, returning the
header's value.

**`Scripting/ScriptMetadata.swift`** — new key `kinds`, comma-separated,
case-insensitive, whitespace-tolerant; names that aren't a `ContentKind`
raw value are ignored (an all-unknown list yields nil, i.e. always
applicable). Same first-30-lines / comment-lead-in rules as the other keys.

```sh
# pastefix: name = Shorten URLs
# pastefix: kinds = url
```

**`Detection/URLFinder.swift`** (new, internal) — the one shared helper the
two URL transforms and the detector use: enumerate `NSDataDetector` link
matches with `http`/`https` schemes, returning `(range: Range<String.Index>,
url: URL)` in document order. Trailing sentence punctuation (`.` `,` `)` `;`
`!` `?` when unbalanced) is excluded from the range so `See https://a.b/c.`
keeps its full stop.

**`Native/URLCleaner.swift`** (new) — `builtin.urlclean`, "Clean URL
Tracking", order 50, `applicableKinds = [.url]`.

- For each found URL, build `URLComponents(url:resolvingAgainstBaseURL:false)`,
  filter `percentEncodedQueryItems` by dropping tracking names (exact list or
  `utm_` prefix, compared case-insensitively on the percent-decoded name), and
  write the result back. If no items remain, `query = nil` so the `?` goes.
  Fragment, path, host, and other items are byte-preserved via the
  percent-encoded API.
- Replaces ranges from the end of the string backwards so earlier ranges stay
  valid. Text outside URLs is untouched. A URL with no tracking params is
  re-emitted verbatim (not round-tripped through `URLComponents`), so nothing
  changes when there's nothing to change.
- The pure core is `static func clean(_ text: String) -> String` and
  `static func cleanURL(_ url: URL) -> URL?`.

**`Native/MarkdownLink.swift`** (new) — `builtin.markdownlink`,
"URL → Markdown Link", order 60, `applicableKinds = [.url]`.

```swift
public protocol TitleFetcher: Sendable {
    func title(for url: URL) async -> String?
}
public struct URLSessionTitleFetcher: TitleFetcher { public init(timeout: TimeInterval = 3, maxBytes: Int = 262_144) }
public struct MarkdownLink: Transformer { public init(fetcher: any TitleFetcher = URLSessionTitleFetcher()) }
```

- For each found URL (skipping any already inside `[...](...)` or `<...>`),
  replace with `[title](url)`. Titles are fetched concurrently in a
  `TaskGroup` capped at 8 in flight; each fetch has its own timeout.
- `URLSessionTitleFetcher`: GET with `Accept: text/html`, an ephemeral session
  (no cookies, no cache), `timeoutIntervalForRequest = timeout`, stops reading
  after `maxBytes` (via a delegate or by truncating the received data —
  implementation detail, but the cap is a hard bound on memory). Parses the
  first `<title>…</title>` case-insensitively, decodes the five XML entities
  plus numeric references, collapses internal whitespace, trims. Returns nil
  on any error, non-2xx status, non-HTML content type, or empty title.
- Fallback title when the fetcher returns nil: `host` + `path` with a trailing
  `/` removed (`example.com/docs/intro`); for a bare host, just the host.
- Markdown-sensitive characters `[` `]` in the title are escaped with a
  backslash; `(` `)` in the URL are percent-encoded so the link parses.
- Pure core: `static func render(_ text: String, titles: [URL: String?]) ->
  String` — the async `apply` gathers titles then calls this. Tests exercise
  `render` and a stub fetcher; no test opens a socket.

**`Native/CaseConvert.swift`** (new) — one struct, four instances registered:

| id | name | order | style |
|---|---|---|---|
| `builtin.case.camel` | camelCase | 70 | `.camel` |
| `builtin.case.snake` | snake_case | 71 | `.snake` |
| `builtin.case.kebab` | kebab-case | 72 | `.kebab` |
| `builtin.case.constant` | CONSTANT_CASE | 73 | `.constant` |

`applicableKinds = nil`. Per line: tokenize, then join.

- **Tokenizer** (`static func words(in line: String) -> [String]`): split on
  any character that is not a letter or digit (spaces, `_`, `-`, `.`, `/`,
  punctuation), then split camel boundaries: lower→Upper (`fooBar` → `foo`,
  `Bar`), Upper-run→Upper+lower (`HTTPServer` → `HTTP`, `Server`),
  letter↔digit boundaries are **not** split (`utf8Decoder` → `utf8`,
  `Decoder`; `v2` stays `v2`). Tokens are lower-cased for joining. Non-ASCII
  letters are letters (Unicode categories), never stripped — that is
  `Transliterate`'s job (Critical Invariant 1).
- **Joiners:** camel = first token lower, rest capitalised (`helloWorld`);
  snake = `lower_lower`; kebab = `lower-lower`; constant = `UPPER_UPPER`.
- A line with no tokens (blank or all punctuation) is emitted unchanged.
  Leading/trailing whitespace of a line is preserved around the converted
  phrase so indented lines stay indented.

**`Discovery/TransformerRegistry.swift`** — five new entries at orders
50, 60, 70–73. `RegistryConfig` gains nothing; `MarkdownLink` is constructed
with the default fetcher. Critical Invariant 8's built-in orders become
`10/20/30/40/50/60/70–73`; scripts still default to 1000.

### `PastefixAppCore`

**`PasteDocument`** gains `public private(set) var detectedKinds:
Set<ContentKind>`, computed from the origin text at init and from the new
working text after every `push` (transform) / `refresh`. Undo/redo restore the
kinds for the text they land on (recompute; it's cheap and avoids storing
history entries twice).

**`PaletteOrdering.swift`** (new)

```swift
public enum PaletteOrdering {
    /// Stable partition: transforms whose applicableKinds intersect `kinds` first,
    /// then the rest, each group in the input order.
    public static func order(_ transformers: [any Transformer], for kinds: Set<ContentKind>) -> [any Transformer]
}
```

With `kinds` empty, the output equals the input (nil-kind transforms are
never promoted; a transform with kinds that don't match is not demoted below
where it already was relative to other non-matching ones).

`AppModel.transformers` (the enable-filtered, user-ordered list from Plan 2b)
is passed through `PaletteOrdering` with `document.detectedKinds` before the
palette renders. `allTransformers` (Settings) is **not** reordered —
the Plan 2b rule "a control surface must never be filtered by the state it
controls" extends to ordering here.

### `Pastefix` app

**`PanelView.swift`** — the palette row gains, at its leading edge, a
secondary-styled caption `Detected: URL` / `Detected: URL, JSON` (kinds in
`CaseIterable` order) when `detectedKinds` is non-empty; nothing when empty.
The palette iterates the ordered list. No other UI change; Settings is
untouched.

## Data flow

Summon → `ClipboardSnapshot` → `PasteDocument(origin:)` computes
`detectedKinds` → `AppModel` publishes → `PanelView` orders the palette and
shows the badge. Click "Clean URL Tracking" → `TransformCoordinator.apply` →
`URLCleaner.apply` (pure, sync inside async) → document `push` → kinds
recomputed (still `url`) → palette re-orders (no visible change). Click
"URL → Markdown Link" → `MarkdownLink.apply` gathers titles with the injected
fetcher (real network in the app, stub in tests) → renders → `push` → the
text now contains Markdown links; the detector still sees URLs, so the badge
stays. Undo restores the prior text and its kinds.

## Error handling

- **`URLCleaner`** cannot fail: a URL that `URLComponents` rejects is left
  verbatim.
- **`MarkdownLink`** cannot fail on network conditions: every fetch error,
  timeout, oversize body, or non-HTML response becomes the `host/path`
  fallback. It surfaces a `TransformError` only in the impossible case of the
  render step throwing, which it doesn't. The existing 3 s `isApplying` gate
  in `AppModel` (Critical Invariant 10) still bounds the UI; the fetcher's own
  3 s timeout keeps the total close to that even with many links because
  fetches run concurrently.
- **`CaseConvert`** cannot fail.
- **Detection** never throws; oversize input yields `[]`.
- **Script `kinds` header** with unknown names is ignored, never an error, so
  a typo doesn't hide a script.

## Testing

All under `Tests/PastefixCoreTests/` and `Tests/PastefixAppCoreTests/`,
Swift Testing, offline.

- `ContentDetectorTests`: single URL; URL inside prose; `www.` bare host;
  `mailto:` not a URL; JSON object; JSON array; JSON fragment (`"x"`, `42`)
  rejected; JSON with leading whitespace; `{` that isn't JSON; empty; over 1 MB
  → `[]`; both kinds at once (a JSON body containing a URL string).
- `URLFinderTests`: trailing `.`/`,`/`)` handling incl. balanced parens in
  Wikipedia-style URLs; adjacent URLs; URL at start/end.
- `URLCleanerTests` (fixture strings): `utm_*` only → `?` removed; mixed
  keep+drop preserving order; `fbclid` in the middle; fragment preserved;
  percent-encoded values byte-preserved; uppercase `UTM_SOURCE`; multiple URLs
  in prose with surrounding text intact; URL with no query unchanged
  byte-for-byte; `ref` dropped but `refresh` kept; metadata (id, order via
  registry, kinds).
- `MarkdownLinkTests` with a `StubTitleFetcher` (dictionary + optional delay):
  title found; fetcher nil → fallback `host/path`; bare host fallback; title
  with entities and newlines normalised; `[`/`]` in title escaped; URL already
  in a Markdown link left alone; multiple URLs, concurrent, order preserved;
  stub that sleeps longer than the timeout → fallback (using a stub timeout,
  not the network); `render` pure-function cases.
- `URLSessionTitleFetcherTests`: parsing only — feed HTML bytes through the
  internal `parseTitle(data:)` helper: normal, uppercase `<TITLE>`, missing,
  truncated at cap, entity decoding, non-UTF8 with charset fallback to
  ISO-8859-1. No sockets.
- `CaseConvertTests`: `hello world` → all four styles; `fooBarBaz`;
  `HTTPServerError`; `utf8Decoder`; `snake_case_input`; `kebab-case-input`;
  `already_CONSTANT`; punctuation `hello, world!`; digits `version 2 beta`;
  multi-line preserves lines and indentation; blank line unchanged; non-ASCII
  `café au lait` → `caféAuLait` (not stripped); metadata for all four ids.
- `ScriptMetadataTests` additions: `kinds = url`, `kinds = URL, json`,
  `kinds = json,unknown` → `[json]`, `kinds = bogus` → nil, absent → nil.
- `TransformerRegistryTests` additions: new ids present with the expected
  orders; `applicableKinds` surfaces through the registry for a fixture script
  with a `kinds` header.
- `PaletteOrderingTests` (AppCore): empty kinds → identity; `url` promotes the
  two URL transforms in their relative order ahead of the rest; a script with
  `kinds = json` is promoted only for `json`; nil-kind transforms never move
  relative to each other.
- `PasteDocumentTests` additions: kinds computed at init, after push, after
  undo/redo, after refresh.

Manual (app): summon with a URL → badge shows, the two URL transforms lead
the palette; Clean URL Tracking strips `utm_*`; URL → Markdown Link produces a
real title for a reachable page and a `host/path` fallback for an unreachable
one; case buttons convert a copied identifier; a plain-text paste shows no
badge and the old palette order.

## Documentation

- `README.md`: the five transforms in "Built-in Transforms"; the `kinds`
  header in "Script Metadata" with the two valid values; a short "Content
  detection" paragraph under the app section describing the badge and
  ordering.
- `AGENTS.md`: layout entries (`Detection/`, the three new `Native/` files,
  `PaletteOrdering.swift`); Critical Invariant 8's order list; a new bullet in
  "Patterns": *transforms that touch the network do so through an injected
  protocol with a hard timeout and a size cap, and tests never open a
  socket*; the status table row for Plan 3.

## Project layout delta

```
Sources/PastefixCore/
  Detection/
    ContentKind.swift            # enum url, json (+ displayName)
    ContentDetector.swift        # detect(_:) -> Set<ContentKind>, 1 MB guard
    URLFinder.swift              # internal: http(s) link ranges via NSDataDetector
  Native/
    URLCleaner.swift             # builtin.urlclean   (order 50, kinds [url])
    MarkdownLink.swift           # builtin.markdownlink (order 60, kinds [url]) + TitleFetcher
    CaseConvert.swift            # builtin.case.{camel,snake,kebab,constant} (70–73)
Sources/PastefixAppCore/
  PaletteOrdering.swift          # applicable-first stable partition
Tests/PastefixCoreTests/         # one suite per new component (see Testing)
Tests/PastefixAppCoreTests/PaletteOrderingTests.swift
```

## Open questions / future increments

- Per-type quick actions (JSON, colours, encoders, JWT) on top of
  `applicableKinds` — the next natural increment.
- User-configurable tracking-parameter list in Settings, if the built-in list
  proves insufficient.
- `code` / `shell` / `sql` kinds once something consumes them.
