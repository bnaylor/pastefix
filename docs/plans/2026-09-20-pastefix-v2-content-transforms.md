# Pastefix v2 Content Transforms & Detection (Plan 3) — Implementation Plan

> ## 🟡 STATUS: IN REVIEW — implemented on `feat/content-transforms` 2026-09-20; [PR #6](https://github.com/bnaylor/pastefix/pull/6) open. All tasks done, including the manual checks and the final-review fix waves.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro` (Swift Testing: `import Testing`, `@Test`, `#expect`, `@Suite`); async → `swift-concurrency-pro`; the one SwiftUI edit → `swiftui-pro`. **TDD is required** for every engine and model task: write the failing test, run it, see it fail for the right reason, implement, see it pass.
>
> **Manual step** (Task 8 Step 5) needs a human driving the app; everything else is automatable.

**Goal:** Five new built-in transforms (Clean URL Tracking, URL → Markdown Link, camelCase, snake_case, kebab-case, CONSTANT_CASE), a pure content detector (URL, JSON), transformer opt-in to content kinds, and a palette that puts applicable transforms first behind a "Detected: …" badge.

**Architecture:** All logic lands in the two tested packages. `PastefixCore` gains `Detection/` (kind enum, detector, URL finder), three `Native/` files, an optional `applicableKinds` on `Transformer` (defaulted, so nothing existing changes), and a `kinds` script-header key. `PastefixAppCore` gains `PasteDocument.detectedKinds` and a pure `PaletteOrdering`. The Xcode target changes two lines in `AppModel` and adds one caption in `PanelView`. Network access exists in exactly one place, `URLSessionTitleFetcher`, behind a `TitleFetcher` protocol with a hard per-URL timeout; tests never open a socket.

**Tech Stack:** Swift 6 SwiftPM (`PastefixCore`, `PastefixAppCore`), Foundation (`NSDataDetector`, `URLComponents`, `JSONSerialization`, `URLSession.bytes`), Swift Testing, SwiftUI for the badge.

**Spec:** `docs/specs/2026-09-20-pastefix-v2-content-transforms.md` — read it first.

## Global Constraints

- **Packages stay dependency-free** (Critical Invariant 4). Foundation only.
- **Transforms are single-purpose** (Critical Invariant 1): case conversion never strips non-ASCII letters (`café` keeps its `é`); URL cleaning never touches text outside URLs; nothing here collapses whitespace.
- **A transform never corrupts the buffer** (Critical Invariant 2): `URLCleaner`, `CaseConvert`, and `MarkdownLink` never throw on their inputs; `MarkdownLink` degrades to the `host/path` fallback on every network problem.
- **Identities and orders** (Critical Invariant 8, extended): `builtin.urlclean` 50, `builtin.markdownlink` 60, `builtin.case.camel` 70, `builtin.case.snake` 71, `builtin.case.kebab` 72, `builtin.case.constant` 73. Scripts still default to 1000.
- **Detection kinds:** exactly `url` and `json`. `url` = at least one `http`/`https` link found by `NSDataDetector` (bare `www.` hosts count, `mailto:` does not). `json` = trimmed text starts with `{` or `[` and `JSONSerialization` parses it without `.fragmentsAllowed`. Buffers over `1_048_576` UTF-8 bytes and empty/whitespace buffers yield `[]`.
- **Tracking parameters:** exact (case-insensitive) `fbclid gclid dclid gbraid wbraid igshid si mc_cid mc_eid ref ref_src _hsenc _hsmi yclid vero_id mkt_tok oly_anon_id oly_enc_id`, plus any name with prefix `utm_`. Compared on the percent-decoded name.
- **Title fetch bounds:** timeout 3 s, read cap 262 144 bytes, ephemeral session, `Accept: text/html`, non-2xx or non-HTML → nil. `MarkdownLink` additionally races every fetch against its own `fetchTimeout` (default 4 s) so a misbehaving fetcher cannot hang the app. Concurrency cap 8.
- **Fallback title:** `host` + `path` with one trailing `/` removed; bare host (`/` or empty path) → just `host`.
- **Case conversion unit:** per line; leading/trailing spaces and tabs of each line preserved; a line with no letter/digit tokens is emitted unchanged.
- **Palette ordering:** stable partition, applicable-first, on top of the user's Plan 2b order. Settings' `allTransformers` is never reordered by detection.
- **No Settings changes. No new SettingsStore keys.**
- **Branch:** `feat/content-transforms` in this checkout (no worktree — the Xcode project's local package path breaks worktree builds). Conventional commits, `Co-Authored-By: Claude <noreply@anthropic.com>` trailer.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/PastefixCore/Detection/ContentKind.swift` | `ContentKind` enum + `displayName` |
| `Sources/PastefixCore/Detection/ContentDetector.swift` | `detect(_:)` with the 1 MB guard |
| `Sources/PastefixCore/Detection/URLFinder.swift` | internal: `http(s)` link ranges via `NSDataDetector`, trailing-punctuation trimming |
| `Sources/PastefixCore/Transformer.swift` | `applicableKinds` requirement + default |
| `Sources/PastefixCore/Scripting/ScriptMetadata.swift` | `kinds` key |
| `Sources/PastefixCore/Scripting/ShellTransformer.swift`, `JSTransformer.swift` | expose `applicableKinds` from metadata |
| `Sources/PastefixCore/Native/URLCleaner.swift` | Clean URL Tracking |
| `Sources/PastefixCore/Native/CaseConvert.swift` | four case styles |
| `Sources/PastefixCore/Native/MarkdownLink.swift` | URL → Markdown Link, `TitleFetcher`, `URLSessionTitleFetcher` |
| `Sources/PastefixCore/Discovery/TransformerRegistry.swift` | register the five |
| `Sources/PastefixAppCore/PasteDocument.swift` | `detectedKinds` |
| `Sources/PastefixAppCore/PaletteOrdering.swift` | applicable-first partition |
| `Pastefix/Pastefix/AppModel.swift`, `PanelView.swift` | ordering + badge |
| `Tests/PastefixCoreTests/{ContentDetector,URLFinder,URLCleaner,CaseConvert,MarkdownLink,TitleParsing}Tests.swift` | new suites |
| `Tests/PastefixCoreTests/{ScriptMetadata,TransformerRegistry}Tests.swift` | extended |
| `Tests/PastefixAppCoreTests/{PaletteOrdering,PasteDocument}Tests.swift` | new / extended |
| `README.md`, `AGENTS.md` | currency |

---

### Task 0: Branch

- [ ] **Step 1**

```bash
git checkout main && git pull --ff-only && git checkout -b feat/content-transforms && swift test 2>&1 | tail -1
```

Expected: `Test run with 66 tests in 14 suites passed`.

---

### Task 1: `ContentKind`, `URLFinder`, `ContentDetector`

**Files:**
- Create: `Sources/PastefixCore/Detection/ContentKind.swift`
- Create: `Sources/PastefixCore/Detection/URLFinder.swift`
- Create: `Sources/PastefixCore/Detection/ContentDetector.swift`
- Test: `Tests/PastefixCoreTests/URLFinderTests.swift`, `Tests/PastefixCoreTests/ContentDetectorTests.swift`

**Interfaces:**
- Produces: `public enum ContentKind: String, CaseIterable, Sendable, Codable { case url, json; public var displayName: String }`; `public enum ContentDetector { public static let maxBytes: Int; public static func detect(_ text: String) -> Set<ContentKind> }`; internal `struct FoundURL { let range: Range<String.Index>; let url: URL; let original: Substring }` and `enum URLFinder { static func find(in text: String) -> [FoundURL] }`.

- [ ] **Step 1: Write the failing tests**

`Tests/PastefixCoreTests/URLFinderTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct URLFinderTests {
    private func urls(_ text: String) -> [String] { URLFinder.find(in: text).map { $0.url.absoluteString } }
    private func originals(_ text: String) -> [String] { URLFinder.find(in: text).map { String($0.original) } }

    @Test func findsSingleURL() {
        #expect(urls("https://example.com/a?b=1") == ["https://example.com/a?b=1"])
    }

    @Test func excludesTrailingSentencePunctuation() {
        #expect(originals("See https://example.com/docs.") == ["https://example.com/docs"])
        #expect(originals("(https://example.com/x), then") == ["https://example.com/x"])
        #expect(originals("Really? https://example.com/y!") == ["https://example.com/y"])
    }

    @Test func keepsBalancedParensInPath() {
        let t = "https://en.wikipedia.org/wiki/Foo_(bar)"
        #expect(originals(t) == [t])
    }

    @Test func bareWWWHostGetsHTTPScheme() {
        let found = URLFinder.find(in: "go to www.example.com now")
        #expect(found.count == 1)
        #expect(found[0].url.absoluteString == "http://www.example.com")
        #expect(String(found[0].original) == "www.example.com")
    }

    @Test func ignoresMailtoAndNonHTTP() {
        #expect(urls("mail me at someone@example.com or ftp://x.y/z") == [])
    }

    @Test func multipleURLsInDocumentOrder() {
        let t = "a https://one.test/ b http://two.test/p c"
        #expect(urls(t) == ["https://one.test/", "http://two.test/p"])
    }

    @Test func rangesAreCorrectForReplacement() {
        var t = "x https://a.test/q y"
        let f = URLFinder.find(in: t)[0]
        t.replaceSubrange(f.range, with: "URL")
        #expect(t == "x URL y")
    }
}
```

`Tests/PastefixCoreTests/ContentDetectorTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct ContentDetectorTests {
    @Test func singleURL() { #expect(ContentDetector.detect("https://example.com") == [.url]) }
    @Test func urlInsideProse() { #expect(ContentDetector.detect("read https://example.com/a today") == [.url]) }
    @Test func bareWWW() { #expect(ContentDetector.detect("www.example.com") == [.url]) }
    @Test func mailtoIsNotURL() { #expect(ContentDetector.detect("someone@example.com") == []) }
    @Test func jsonObject() { #expect(ContentDetector.detect("{\"a\": 1}") == [.json]) }
    @Test func jsonArray() { #expect(ContentDetector.detect("[1, 2, 3]") == [.json]) }
    @Test func jsonWithLeadingWhitespace() { #expect(ContentDetector.detect("\n  {\"a\": [1]}\n") == [.json]) }
    @Test func jsonFragmentsRejected() {
        #expect(ContentDetector.detect("\"x\"") == [])
        #expect(ContentDetector.detect("42") == [])
    }
    @Test func braceThatIsNotJSON() { #expect(ContentDetector.detect("{ not json }") == []) }
    @Test func plainText() { #expect(ContentDetector.detect("hello world") == []) }
    @Test func empty() {
        #expect(ContentDetector.detect("") == [])
        #expect(ContentDetector.detect("   \n") == [])
    }
    @Test func bothKinds() {
        #expect(ContentDetector.detect("{\"link\": \"https://example.com\"}") == [.url, .json])
    }
    @Test func oversizeYieldsNothing() {
        let big = String(repeating: "https://example.com ", count: 60_000)   // ~1.2 MB
        #expect(big.utf8.count > ContentDetector.maxBytes)
        #expect(ContentDetector.detect(big) == [])
    }
    @Test func displayNames() {
        #expect(ContentKind.url.displayName == "URL")
        #expect(ContentKind.json.displayName == "JSON")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter "URLFinderTests|ContentDetectorTests" 2>&1 | tail -5
```

Expected: compile errors (`URLFinder`, `ContentDetector`, `ContentKind` undefined).

- [ ] **Step 3: Implement**

`Sources/PastefixCore/Detection/ContentKind.swift`:

```swift
import Foundation

/// What the detector recognised in the working buffer. Transforms may opt in to
/// kinds via `Transformer.applicableKinds`; the palette shows those first.
public enum ContentKind: String, CaseIterable, Sendable, Codable {
    case url
    case json

    /// Label for the "Detected: …" badge.
    public var displayName: String {
        switch self {
        case .url: return "URL"
        case .json: return "JSON"
        }
    }
}
```

`Sources/PastefixCore/Detection/URLFinder.swift`:

```swift
import Foundation

/// An http(s) link located in a string. `original` is the text as written (may lack a
/// scheme, e.g. `www.example.com`); `url` always has one.
struct FoundURL {
    let range: Range<String.Index>
    let url: URL
    let original: Substring
}

/// The one shared way the engine finds links: NSDataDetector, http/https only, with
/// trailing sentence punctuation excluded so "see https://a.b/c." keeps its full stop.
enum URLFinder {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(in text: String) -> [FoundURL] {
        let ns = text as NSString
        var out: [FoundURL] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard var range = Range(match.range, in: text) else { continue }
            while range.lowerBound < range.upperBound,
                  shouldTrim(text[text.index(before: range.upperBound)], in: text[range]) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            let original = text[range]
            guard !original.isEmpty else { continue }
            let candidate = original.contains("://") ? String(original) : "http://" + original
            guard let url = URL(string: candidate) ?? match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            out.append(FoundURL(range: range, url: url, original: original))
        }
        return out
    }

    private static func shouldTrim(_ last: Character, in s: Substring) -> Bool {
        switch last {
        case ".", ",", ";", ":", "!", "?", "'", "\"": return true
        case ")": return s.filter { $0 == "(" }.count < s.filter { $0 == ")" }.count
        default: return false
        }
    }
}
```

`Sources/PastefixCore/Detection/ContentDetector.swift`:

```swift
import Foundation

public enum ContentDetector {
    /// Buffers larger than this are not inspected; the badge is a nicety, summon latency is not.
    public static let maxBytes = 1_048_576

    public static func detect(_ text: String) -> Set<ContentKind> {
        guard text.utf8.count <= maxBytes else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var kinds: Set<ContentKind> = []
        if !URLFinder.find(in: text).isEmpty { kinds.insert(.url) }
        if let first = trimmed.first, first == "{" || first == "[",
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [])) != nil {
            kinds.insert(.json)
        }
        return kinds
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter "URLFinderTests|ContentDetectorTests" 2>&1 | tail -3
```

Expected: all pass. If `excludesTrailingSentencePunctuation` fails because `NSDataDetector` already excluded the punctuation, the test still passes (the loop is a no-op); if `keepsBalancedParensInPath` fails because the detector *stopped* before `(bar)`, extend the expectation to what the detector returns and note it in the report — do not fight the detector.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Detection Tests/PastefixCoreTests/URLFinderTests.swift Tests/PastefixCoreTests/ContentDetectorTests.swift
git commit -m "feat(core): add ContentKind, URLFinder, and ContentDetector

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: `applicableKinds` on `Transformer` + `kinds` script header

**Files:**
- Modify: `Sources/PastefixCore/Transformer.swift` (protocol, ~line 29)
- Modify: `Sources/PastefixCore/Scripting/ScriptMetadata.swift`
- Modify: `Sources/PastefixCore/Scripting/ShellTransformer.swift`, `Sources/PastefixCore/Scripting/JSTransformer.swift`
- Test: `Tests/PastefixCoreTests/ScriptMetadataTests.swift` (extend), `Tests/PastefixCoreTests/TransformerRegistryTests.swift` (extend)

**Interfaces:**
- Produces: `Transformer.applicableKinds: Set<ContentKind>?` (default nil); `ScriptMetadata.kinds: Set<ContentKind>?`; `ShellTransformer`/`JSTransformer` return `metadata.kinds`.

- [ ] **Step 1: Failing tests** — append to `ScriptMetadataTests`:

```swift
    @Test func parsesKinds() {
        #expect(ScriptMetadata.parse("# pastefix: kinds = url").kinds == [.url])
        #expect(ScriptMetadata.parse("# pastefix: kinds = URL, json").kinds == [.url, .json])
        #expect(ScriptMetadata.parse("# pastefix: kinds = json,unknown").kinds == [.json])
        #expect(ScriptMetadata.parse("# pastefix: kinds = bogus").kinds == nil)
        #expect(ScriptMetadata.parse("# pastefix: name = X").kinds == nil)
    }
```

and to `TransformerRegistryTests`:

```swift
    @Test func scriptKindsSurfaceAsApplicableKinds() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = URLy\n# pastefix: kinds = url\ncat".write(
            to: dir.appendingPathComponent("urly.sh"), atomically: true, encoding: .utf8)
        try "// pastefix: name = Plain\nfunction transform(t){return t;}".write(
            to: dir.appendingPathComponent("plain.js"), atomically: true, encoding: .utf8)
        let loaded = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load()
        #expect(loaded.first { $0.name == "URLy" }?.applicableKinds == [.url])
        #expect(loaded.first { $0.name == "Plain" }?.applicableKinds == nil)
        #expect(loaded.first { $0.id == "builtin.whitespace" }?.applicableKinds == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter "ScriptMetadataTests|TransformerRegistryTests" 2>&1 | grep -E "error|failed|passed" | head -5
```

Expected: compile error, `kinds`/`applicableKinds` unknown.

- [ ] **Step 3: Implement**

In `Transformer.swift`, add to the protocol after `source`:

```swift
    /// Content kinds this transform is meant for. `nil` (the default) means always
    /// applicable. The palette lists matching transforms first; nothing is hidden.
    var applicableKinds: Set<ContentKind>? { get }
```

and below the protocol:

```swift
public extension Transformer {
    var applicableKinds: Set<ContentKind>? { nil }
}
```

In `ScriptMetadata.swift`: add `public var kinds: Set<ContentKind>?`, add `kinds: Set<ContentKind>? = nil` as the last init parameter (assign it), and add a `case "kinds":` in the switch:

```swift
            case "kinds":
                let parsed = value.split(separator: ",")
                    .compactMap { ContentKind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
                md.kinds = parsed.isEmpty ? nil : Set(parsed)
```

In both `ShellTransformer` and `JSTransformer`: add `public let applicableKinds: Set<ContentKind>?` and `self.applicableKinds = metadata.kinds` in `init`.

- [ ] **Step 4: Run the whole suite** (the protocol change touches everything)

```bash
swift test 2>&1 | tail -1
```

Expected: everything passes (existing `ScriptMetadata(...)` equality tests still hold because `kinds` defaults to nil).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Transformer.swift Sources/PastefixCore/Scripting Tests/PastefixCoreTests/ScriptMetadataTests.swift Tests/PastefixCoreTests/TransformerRegistryTests.swift
git commit -m "feat(core): transformers may declare applicableKinds; scripts via 'kinds' header

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: `URLCleaner`

**Files:**
- Create: `Sources/PastefixCore/Native/URLCleaner.swift`
- Test: `Tests/PastefixCoreTests/URLCleanerTests.swift`

**Interfaces:**
- Consumes: `URLFinder.find(in:)`, `FoundURL.original`.
- Produces: `public struct URLCleaner: Transformer` (`builtin.urlclean`, "Clean URL Tracking", `applicableKinds = [.url]`), `static func clean(_ text: String) -> String`, `static func cleanURL(_ url: URL) -> URL?` (nil = nothing to change), `static func isTracking(_ name: String) -> Bool`.

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct URLCleanerTests {
    let subject = URLCleaner()
    private func clean(_ s: String) -> String { URLCleaner.clean(s) }

    @Test func stripsUTMAndRemovesEmptyQuery() {
        #expect(clean("https://ex.com/p?utm_source=a&utm_medium=b") == "https://ex.com/p")
    }
    @Test func keepsOtherParamsInOrder() {
        #expect(clean("https://ex.com/p?a=1&utm_source=x&b=2&fbclid=Z&c=3") == "https://ex.com/p?a=1&b=2&c=3")
    }
    @Test func preservesFragment() {
        #expect(clean("https://ex.com/p?utm_campaign=c#section-2") == "https://ex.com/p#section-2")
    }
    @Test func preservesPercentEncodingOfKeptValues() {
        #expect(clean("https://ex.com/s?q=a%20b%26c&gclid=1") == "https://ex.com/s?q=a%20b%26c")
    }
    @Test func caseInsensitiveNames() {
        #expect(clean("https://ex.com/?UTM_SOURCE=x&FBCLID=y&Keep=1") == "https://ex.com/?Keep=1")
    }
    @Test func refDroppedButRefreshKept() {
        #expect(clean("https://ex.com/?ref=tw&refresh=1") == "https://ex.com/?refresh=1")
    }
    @Test func multipleURLsInProseTextIntact() {
        let input = "See https://a.test/x?utm_source=1 and (https://b.test/y?id=2&si=abc), ok."
        #expect(clean(input) == "See https://a.test/x and (https://b.test/y?id=2), ok.")
    }
    @Test func untouchedURLIsByteIdentical() {
        let odd = "https://ex.com/a%2Fb?x=%7E&y=1#frag"
        #expect(clean("go \(odd) now") == "go \(odd) now")
    }
    @Test func noQueryUnchanged() { #expect(clean("https://ex.com/path") == "https://ex.com/path") }
    @Test func bareWWWKeepsItsForm() {
        #expect(clean("www.ex.com/p?utm_source=a&k=1") == "www.ex.com/p?k=1")
    }
    @Test func plainTextUnchanged() { #expect(clean("no links here") == "no links here") }
    @Test func isTrackingList() {
        #expect(URLCleaner.isTracking("utm_anything"))
        #expect(URLCleaner.isTracking("mc_eid"))
        #expect(!URLCleaner.isTracking("id"))
    }
    @Test func applyAndMetadata() async throws {
        #expect(try await subject.apply(.init(text: "https://ex.com/?utm_x=1")) == "https://ex.com/")
        #expect(subject.id == "builtin.urlclean")
        #expect(subject.applicableKinds == [.url])
        #expect(subject.source == .builtin)
        #expect(subject.requiresRichInput == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter URLCleanerTests 2>&1 | tail -3
```

- [ ] **Step 3: Implement** `Sources/PastefixCore/Native/URLCleaner.swift`:

```swift
import Foundation

/// Removes tracking query parameters from every http(s) URL in the buffer.
/// Text outside URLs, and URLs with nothing to remove, are left byte-for-byte.
public struct URLCleaner: Transformer {
    public let id = "builtin.urlclean"
    public let name = "Clean URL Tracking"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.url]

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        Self.clean(input.text)
    }

    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "igshid", "si", "mc_cid", "mc_eid",
        "ref", "ref_src", "_hsenc", "_hsmi", "yclid", "vero_id", "mkt_tok", "oly_anon_id", "oly_enc_id",
    ]

    static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || trackingNames.contains(n)
    }

    /// nil when the URL has no tracking parameters (caller keeps the original text).
    static func cleanURL(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let kept = items.filter { !isTracking($0.name.removingPercentEncoding ?? $0.name) }
        guard kept.count != items.count else { return nil }
        comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return comps.url
    }

    static func clean(_ text: String) -> String {
        var out = text
        for found in URLFinder.find(in: text).reversed() {
            guard let cleaned = cleanURL(found.url) else { continue }
            var replacement = cleaned.absoluteString
            if !found.original.contains("://"), let schemeEnd = replacement.range(of: "://") {
                replacement = String(replacement[schemeEnd.upperBound...])   // keep the bare-www form
            }
            out.replaceSubrange(found.range, with: replacement)
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter URLCleanerTests 2>&1 | tail -3
```

If `preservesPercentEncodingOfKeptValues` or `untouchedURLIsByteIdentical` fails because `URLComponents` re-normalises encoding, that is a real finding: switch `cleanURL` to a string-based rewrite of the query (split on `&`, drop tracking pairs, rejoin) instead of `URLComponents`, keep the tests as written, and say so in the report.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Native/URLCleaner.swift Tests/PastefixCoreTests/URLCleanerTests.swift
git commit -m "feat(core): add Clean URL Tracking transform

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: `CaseConvert`

**Files:**
- Create: `Sources/PastefixCore/Native/CaseConvert.swift`
- Test: `Tests/PastefixCoreTests/CaseConvertTests.swift`

**Interfaces:**
- Produces: `public struct CaseConvert: Transformer { public enum Style: Sendable { case camel, snake, kebab, constant }; public init(style: Style) }`; ids/names per Global Constraints; `static func words(in line: String) -> [String]`; `static func convert(_ text: String, style: Style) -> String`.

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import PastefixCore

@Suite struct CaseConvertTests {
    private func all(_ s: String) -> [String] {
        [CaseConvert.Style.camel, .snake, .kebab, .constant].map { CaseConvert.convert(s, style: $0) }
    }

    @Test func words() {
        #expect(CaseConvert.words(in: "hello world") == ["hello", "world"])
        #expect(CaseConvert.words(in: "fooBarBaz") == ["foo", "bar", "baz"])
        #expect(CaseConvert.words(in: "HTTPServerError") == ["http", "server", "error"])
        #expect(CaseConvert.words(in: "utf8Decoder") == ["utf8", "decoder"])
        #expect(CaseConvert.words(in: "v2") == ["v2"])
        #expect(CaseConvert.words(in: "snake_case_input") == ["snake", "case", "input"])
        #expect(CaseConvert.words(in: "kebab-case-input") == ["kebab", "case", "input"])
        #expect(CaseConvert.words(in: "already_CONSTANT") == ["already", "constant"])
        #expect(CaseConvert.words(in: "hello, world!") == ["hello", "world"])
        #expect(CaseConvert.words(in: "version 2 beta") == ["version", "2", "beta"])
        #expect(CaseConvert.words(in: "café au lait") == ["café", "au", "lait"])
        #expect(CaseConvert.words(in: "---") == [])
    }

    @Test func helloWorldAllStyles() {
        #expect(all("hello world") == ["helloWorld", "hello_world", "hello-world", "HELLO_WORLD"])
    }
    @Test func acronyms() {
        #expect(all("HTTPServerError") == ["httpServerError", "http_server_error", "http-server-error", "HTTP_SERVER_ERROR"])
    }
    @Test func nonASCIILettersKept() {
        #expect(CaseConvert.convert("café au lait", style: .camel) == "caféAuLait")
    }
    @Test func perLineWithIndentationPreserved() {
        let input = "  first line\n\tsecond_line  \n\nlast"
        #expect(CaseConvert.convert(input, style: .kebab) == "  first-line\n\tsecond-line  \n\nlast")
    }
    @Test func lineWithoutTokensUnchanged() {
        #expect(CaseConvert.convert("--- ***", style: .snake) == "--- ***")
    }
    @Test func metadata() async throws {
        let cases: [(CaseConvert.Style, String, String)] = [
            (.camel, "builtin.case.camel", "camelCase"),
            (.snake, "builtin.case.snake", "snake_case"),
            (.kebab, "builtin.case.kebab", "kebab-case"),
            (.constant, "builtin.case.constant", "CONSTANT_CASE"),
        ]
        for (style, id, name) in cases {
            let t = CaseConvert(style: style)
            #expect(t.id == id)
            #expect(t.name == name)
            #expect(t.applicableKinds == nil)
            #expect(t.source == .builtin)
            #expect(try await t.apply(.init(text: "a b")).isEmpty == false)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter CaseConvertTests 2>&1 | tail -3
```

- [ ] **Step 3: Implement** `Sources/PastefixCore/Native/CaseConvert.swift`:

```swift
import Foundation

/// Rewrites each line as one identifier phrase in the chosen case style.
/// Splits on separators and camel boundaries; keeps digits with their word; keeps
/// non-ASCII letters (Transliterate owns ASCII folding).
public struct CaseConvert: Transformer {
    public enum Style: Sendable { case camel, snake, kebab, constant }

    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = nil
    public let style: Style

    public init(style: Style) {
        self.style = style
        switch style {
        case .camel:    id = "builtin.case.camel";    name = "camelCase"
        case .snake:    id = "builtin.case.snake";    name = "snake_case"
        case .kebab:    id = "builtin.case.kebab";    name = "kebab-case"
        case .constant: id = "builtin.case.constant"; name = "CONSTANT_CASE"
        }
    }

    public func apply(_ input: TransformInput) async throws -> String {
        Self.convert(input.text, style: style)
    }

    static func convert(_ text: String, style: Style) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let trail = line.reversed().prefix { $0 == " " || $0 == "\t" }
            let core = line.dropFirst(lead.count).dropLast(trail.count)
            let ws = words(in: String(core))
            guard !ws.isEmpty else { return line }
            return String(lead) + join(ws, style: style) + String(trail.reversed())
        }.joined(separator: "\n")
    }

    /// Lower-cased tokens. Boundaries: any non-letter/digit; lower→Upper; Upper-run→Upper+lower;
    /// digit→Upper. Letter↔digit inside a run does not split ("v2", "utf8").
    static func words(in line: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(line)
        func flush() { if !current.isEmpty { words.append(current.lowercased()); current = "" } }
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else { flush(); continue }
            if c.isUppercase, !current.isEmpty {
                let prev = chars[i - 1]
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if prev.isLowercase || prev.isNumber {
                    flush()
                } else if prev.isUppercase, let n = next, n.isLowercase {
                    flush()
                }
            }
            current.append(c)
        }
        flush()
        return words
    }

    private static func join(_ words: [String], style: Style) -> String {
        switch style {
        case .camel:
            guard let first = words.first else { return "" }
            return first + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case .snake: return words.joined(separator: "_")
        case .kebab: return words.joined(separator: "-")
        case .constant: return words.map { $0.uppercased() }.joined(separator: "_")
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter CaseConvertTests 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Native/CaseConvert.swift Tests/PastefixCoreTests/CaseConvertTests.swift
git commit -m "feat(core): add camelCase, snake_case, kebab-case, CONSTANT_CASE transforms

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: `MarkdownLink`, `TitleFetcher`, `URLSessionTitleFetcher`

**Files:**
- Create: `Sources/PastefixCore/Native/MarkdownLink.swift`
- Test: `Tests/PastefixCoreTests/MarkdownLinkTests.swift`, `Tests/PastefixCoreTests/TitleParsingTests.swift`

**Interfaces:**
- Consumes: `URLFinder`.
- Produces: `public protocol TitleFetcher: Sendable { func title(for url: URL) async -> String? }`; `public struct URLSessionTitleFetcher: TitleFetcher { public init(timeout: TimeInterval = 3, maxBytes: Int = 262_144); static func parseTitle(data: Data) -> String?; static func decodeEntities(_ s: String) -> String }`; `public struct MarkdownLink: Transformer { public init(fetcher: any TitleFetcher = URLSessionTitleFetcher(), fetchTimeout: TimeInterval = 4); static func render(_ text: String, titles: [URL: String]) -> String; static func fallbackTitle(for url: URL) -> String }`.

- [ ] **Step 1: Failing tests**

`Tests/PastefixCoreTests/MarkdownLinkTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

/// Offline fetcher: returns canned titles; optional delay; records calls.
actor CallLog { var urls: [URL] = []; func add(_ u: URL) { urls.append(u) } }

struct StubTitleFetcher: TitleFetcher {
    var titles: [String: String] = [:]
    var delay: Duration = .zero
    var log = CallLog()
    func title(for url: URL) async -> String? {
        await log.add(url)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return titles[url.absoluteString]
    }
}

@Suite struct MarkdownLinkTests {
    @Test func rendersFetchedTitle() async throws {
        let t = MarkdownLink(fetcher: StubTitleFetcher(titles: ["https://ex.com/a": "Example A"]))
        #expect(try await t.apply(.init(text: "see https://ex.com/a today")) == "see [Example A](https://ex.com/a) today")
    }
    @Test func fallbackWhenFetcherReturnsNil() async throws {
        let t = MarkdownLink(fetcher: StubTitleFetcher())
        #expect(try await t.apply(.init(text: "https://ex.com/docs/intro/")) == "[ex.com/docs/intro](https://ex.com/docs/intro/)")
    }
    @Test func bareHostFallback() {
        #expect(MarkdownLink.fallbackTitle(for: URL(string: "https://ex.com/")!) == "ex.com")
        #expect(MarkdownLink.fallbackTitle(for: URL(string: "https://ex.com")!) == "ex.com")
    }
    @Test func escapesBracketsInTitle() {
        let out = MarkdownLink.render("https://ex.com/x", titles: [URL(string: "https://ex.com/x")!: "A [b] c"])
        #expect(out == "[A \\[b\\] c](https://ex.com/x)")
    }
    @Test func percentEncodesParensInURL() {
        let u = "https://en.wikipedia.org/wiki/Foo_(bar)"
        let out = MarkdownLink.render(u, titles: [URL(string: u)!: "Foo"])
        #expect(out == "[Foo](https://en.wikipedia.org/wiki/Foo_%28bar%29)")
    }
    @Test func leavesExistingMarkdownLinksAlone() {
        let text = "[Already](https://ex.com/a) and <https://ex.com/b> and https://ex.com/c"
        let titles = [URL(string: "https://ex.com/c")!: "C"]
        #expect(MarkdownLink.render(text, titles: titles) == "[Already](https://ex.com/a) and <https://ex.com/b> and [C](https://ex.com/c)")
    }
    @Test func multipleURLsPreserveOrderAndFetchEachOnce() async throws {
        let stub = StubTitleFetcher(titles: ["https://one.test/": "One", "https://two.test/": "Two"])
        let t = MarkdownLink(fetcher: stub)
        let out = try await t.apply(.init(text: "https://one.test/ https://two.test/ https://one.test/"))
        #expect(out == "[One](https://one.test/) [Two](https://two.test/) [One](https://one.test/)")
        #expect(await stub.log.urls.count == 2)
    }
    @Test func slowFetcherFallsBackWithinTimeout() async throws {
        let t = MarkdownLink(fetcher: StubTitleFetcher(delay: .seconds(10)), fetchTimeout: 0.2)
        let start = ContinuousClock.now
        let out = try await t.apply(.init(text: "https://slow.test/p"))
        #expect(out == "[slow.test/p](https://slow.test/p)")
        #expect(ContinuousClock.now - start < .seconds(3))
    }
    @Test func noURLsUnchanged() async throws {
        #expect(try await MarkdownLink(fetcher: StubTitleFetcher()).apply(.init(text: "plain")) == "plain")
    }
    @Test func metadata() {
        let t = MarkdownLink(fetcher: StubTitleFetcher())
        #expect(t.id == "builtin.markdownlink")
        #expect(t.name == "URL → Markdown Link")
        #expect(t.applicableKinds == [.url])
    }
}
```

`Tests/PastefixCoreTests/TitleParsingTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct TitleParsingTests {
    private func parse(_ html: String) -> String? { URLSessionTitleFetcher.parseTitle(data: Data(html.utf8)) }

    @Test func simple() { #expect(parse("<html><head><title>Hello</title></head></html>") == "Hello") }
    @Test func caseInsensitiveAndAttributes() { #expect(parse("<TITLE lang=\"en\">Hi</TITLE>") == "Hi") }
    @Test func missing() { #expect(parse("<html><body>no title</body></html>") == nil) }
    @Test func emptyIsNil() { #expect(parse("<title>   </title>") == nil) }
    @Test func whitespaceCollapsed() { #expect(parse("<title>\n  Two\n   lines \n</title>") == "Two lines") }
    @Test func entitiesDecoded() {
        #expect(parse("<title>A &amp; B &lt;C&gt; &quot;D&quot; &#39;E&#39; &#8212; &#x2014;</title>") == "A & B <C> \"D\" 'E' — —")
    }
    @Test func truncatedAtCapHasNoCloseTag() { #expect(parse("<title>Unfinished") == nil) }
    @Test func latin1Fallback() {
        let bytes: [UInt8] = Array("<title>caf".utf8) + [0xE9] + Array("</title>".utf8)   // é in ISO-8859-1
        #expect(URLSessionTitleFetcher.parseTitle(data: Data(bytes)) == "café")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter "MarkdownLinkTests|TitleParsingTests" 2>&1 | tail -3
```

- [ ] **Step 3: Implement** `Sources/PastefixCore/Native/MarkdownLink.swift`:

```swift
import Foundation

/// Fetches an HTML page title. The engine's only network access; injected so tests stay offline.
public protocol TitleFetcher: Sendable {
    func title(for url: URL) async -> String?
}

public struct URLSessionTitleFetcher: TitleFetcher {
    public let timeout: TimeInterval
    public let maxBytes: Int

    public init(timeout: TimeInterval = 3, maxBytes: Int = 262_144) {
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    public func title(for url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  (http.mimeType ?? "").lowercased().contains("html") else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
            return Self.parseTitle(data: data)
        } catch {
            return nil
        }
    }

    static func parseTitle(data: Data) -> String? {
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        guard let open = html.range(of: "<title[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        let raw = decodeEntities(String(html[open.upperBound..<close.lowerBound]))
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        // Numeric references first so "&amp;#39;" style double-encoding isn't mis-decoded.
        for pattern in ["&#x([0-9A-Fa-f]+);", "&#([0-9]+);"] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            var result = out
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let digits = ns.substring(with: m.range(at: 1))
                let code = pattern.contains("x") ? UInt32(digits, radix: 16) : UInt32(digits)
                if let code, let scalar = Unicode.Scalar(code), let r = Range(m.range, in: result) {
                    result.replaceSubrange(r, with: String(Character(scalar)))
                }
            }
            out = result
        }
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ", "&amp;": "&"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

/// Replaces each http(s) URL with `[title](url)`, fetching titles concurrently with a hard
/// per-URL bound; falls back to `host/path` on any failure so the transform never errors.
public struct MarkdownLink: Transformer {
    public let id = "builtin.markdownlink"
    public let name = "URL → Markdown Link"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.url]

    private let fetcher: any TitleFetcher
    private let fetchTimeout: TimeInterval
    private static let maxConcurrentFetches = 8

    public init(fetcher: any TitleFetcher = URLSessionTitleFetcher(), fetchTimeout: TimeInterval = 4) {
        self.fetcher = fetcher
        self.fetchTimeout = fetchTimeout
    }

    public func apply(_ input: TransformInput) async throws -> String {
        let candidates = Self.linkable(in: input.text)
        guard !candidates.isEmpty else { return input.text }
        var unique: [URL] = []
        var seen = Set<URL>()
        for c in candidates where seen.insert(c.url).inserted { unique.append(c.url) }

        let fetcher = self.fetcher
        let timeout = self.fetchTimeout
        var titles: [URL: String] = [:]
        await withTaskGroup(of: (URL, String?).self) { group in
            var next = 0
            func spawn() {
                let url = unique[next]; next += 1
                group.addTask { (url, await Self.fetchBounded(url, fetcher: fetcher, timeout: timeout)) }
            }
            while next < unique.count, next < Self.maxConcurrentFetches { spawn() }
            for await (url, title) in group {
                if let title { titles[url] = title }
                if next < unique.count { spawn() }
            }
        }
        return Self.render(input.text, titles: titles)
    }

    /// Races the fetcher against a sleep so a hung fetcher cannot hang the app.
    static func fetchBounded(_ url: URL, fetcher: any TitleFetcher, timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await fetcher.title(for: url) }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// URLs eligible for wrapping: not already inside `[...](...)` or `<...>`.
    static func linkable(in text: String) -> [FoundURL] {
        URLFinder.find(in: text).filter { f in
            let before = text[..<f.range.lowerBound]
            let after = text[f.range.upperBound...]
            if before.hasSuffix("](") { return false }
            if before.hasSuffix("<"), after.hasPrefix(">") { return false }
            return true
        }
    }

    static func fallbackTitle(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        var path = url.path
        if path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? host : host + path
    }

    static func render(_ text: String, titles: [URL: String]) -> String {
        var out = text
        for found in linkable(in: text).reversed() {
            let title = (titles[found.url] ?? fallbackTitle(for: found.url))
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            let target = String(found.original)
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            out.replaceSubrange(found.range, with: "[\(title)](\(target))")
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter "MarkdownLinkTests|TitleParsingTests" 2>&1 | tail -3
```

Likely compile issue: the nested `spawn()` capturing the `inout` task group. If the compiler rejects it, inline the two `group.addTask` calls (one in the priming `while`, one in the `for await`) instead of the nested func. Under strict concurrency, `StubTitleFetcher` must be `Sendable` — it is a struct of Sendable members plus an actor reference, so it is.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Native/MarkdownLink.swift Tests/PastefixCoreTests/MarkdownLinkTests.swift Tests/PastefixCoreTests/TitleParsingTests.swift
git commit -m "feat(core): add URL → Markdown Link transform with bounded title fetching

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Register the five built-ins

**Files:**
- Modify: `Sources/PastefixCore/Discovery/TransformerRegistry.swift:25-30`
- Modify: `Tests/PastefixCoreTests/TransformerRegistryTests.swift` (two existing expectations)

- [ ] **Step 1: Update the existing tests first** (they will fail until registration lands):

In `loadsBuiltinsInOrderWhenNoScripts` replace the expected array with:

```swift
        #expect(ids == [
            "builtin.richtoplain", "builtin.transliterate", "builtin.wrapreflow", "builtin.whitespace",
            "builtin.urlclean", "builtin.markdownlink",
            "builtin.case.camel", "builtin.case.snake", "builtin.case.kebab", "builtin.case.constant",
        ])
```

In `toleratesMissingDirectory` change `count == 4` to `count == 10`.

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter TransformerRegistryTests 2>&1 | grep -E "failed|passed" | tail -3
```

Expected: those two tests fail.

- [ ] **Step 3: Register** — the `entries` literal becomes:

```swift
        var entries: [(order: Int, name: String, transformer: any Transformer)] = [
            (10, "Rich → Plain Text", RichToPlain()),
            (20, "Transliterate to ASCII", Transliterate()),
            (30, "Wrap & Reflow", WrapReflow(width: config.wrapWidth)),
            (40, "Whitespace Cleanup", WhitespaceCleanup()),
            (50, "Clean URL Tracking", URLCleaner()),
            (60, "URL → Markdown Link", MarkdownLink()),
            (70, "camelCase", CaseConvert(style: .camel)),
            (71, "snake_case", CaseConvert(style: .snake)),
            (72, "kebab-case", CaseConvert(style: .kebab)),
            (73, "CONSTANT_CASE", CaseConvert(style: .constant)),
        ]
```

- [ ] **Step 4: Full suite**

```bash
swift test 2>&1 | tail -1
```

Expected: all pass. (`discoversAndOrdersScriptsAmongBuiltins` still holds: Early is 5, LateJS is 1000.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Discovery/TransformerRegistry.swift Tests/PastefixCoreTests/TransformerRegistryTests.swift
git commit -m "feat(core): register URL, Markdown link, and case transforms at orders 50-73

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: `PasteDocument.detectedKinds` and `PaletteOrdering`

**Files:**
- Modify: `Sources/PastefixAppCore/PasteDocument.swift`
- Create: `Sources/PastefixAppCore/PaletteOrdering.swift`
- Test: `Tests/PastefixAppCoreTests/PasteDocumentTests.swift` (extend), `Tests/PastefixAppCoreTests/PaletteOrderingTests.swift` (new)

**Interfaces:**
- Consumes: `ContentDetector`, `ContentKind`, `Transformer.applicableKinds`.
- Produces: `PasteDocument.detectedKinds: Set<ContentKind>` (read-only, always current for `working`); `public enum PaletteOrdering { public static func order(_ transformers: [any Transformer], for kinds: Set<ContentKind>) -> [any Transformer] }`.

- [ ] **Step 1: Failing tests** — append to `PasteDocumentTests`:

```swift
    @Test func detectedKindsTrackWorkingText() {
        var d = doc("https://example.com")
        #expect(d.detectedKinds == [.url])
        d.pushState("{\"a\":1}")
        #expect(d.detectedKinds == [.json])
        d.undo()
        #expect(d.detectedKinds == [.url])
        d.redo()
        #expect(d.detectedKinds == [.json])
        d.setWorking("plain")
        #expect(d.detectedKinds == [])
        d.refresh(origin: ClipboardSnapshot(plainText: "www.example.com", richRTFD: nil))
        #expect(d.detectedKinds == [.url])
    }
```

(`PasteDocumentTests` needs `import PastefixCore` for `ContentKind` — add it.)

`Tests/PastefixAppCoreTests/PaletteOrderingTests.swift`:

```swift
import Testing
import PastefixCore
@testable import PastefixAppCore

private struct FakeTransformer: Transformer {
    let id: String
    let applicableKinds: Set<ContentKind>?
    var name: String { id }
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite struct PaletteOrderingTests {
    let list: [any Transformer] = [
        FakeTransformer(id: "plain1", applicableKinds: nil),
        FakeTransformer(id: "urlA", applicableKinds: [.url]),
        FakeTransformer(id: "plain2", applicableKinds: nil),
        FakeTransformer(id: "json1", applicableKinds: [.json]),
        FakeTransformer(id: "urlB", applicableKinds: [.url]),
    ]
    private func ids(_ kinds: Set<ContentKind>) -> [String] { PaletteOrdering.order(list, for: kinds).map(\.id) }

    @Test func emptyKindsIsIdentity() { #expect(ids([]) == ["plain1", "urlA", "plain2", "json1", "urlB"]) }
    @Test func urlPromotesURLTransformsInRelativeOrder() { #expect(ids([.url]) == ["urlA", "urlB", "plain1", "plain2", "json1"]) }
    @Test func jsonPromotesOnlyJSON() { #expect(ids([.json]) == ["json1", "plain1", "urlA", "plain2", "urlB"]) }
    @Test func bothKindsKeepInputOrderWithinFront() { #expect(ids([.url, .json]) == ["urlA", "json1", "urlB", "plain1", "plain2"]) }
    @Test func nilKindTransformsNeverMoveRelativeToEachOther() {
        let out = ids([.url])
        #expect(out.firstIndex(of: "plain1")! < out.firstIndex(of: "plain2")!)
    }
}
```

If `TransformOverridesTests` already defines a fake transformer with the same name, reuse it (make it `applicableKinds`-aware) instead of adding a second.

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter "PasteDocumentTests|PaletteOrderingTests" 2>&1 | tail -3
```

- [ ] **Step 3: Implement**

`PasteDocument.swift`: add `import PastefixCore`; add `public private(set) var detectedKinds: Set<ContentKind>`; in `init` after `cursor = 0` add `self.detectedKinds = ContentDetector.detect(history[0])`; add a private helper `private mutating func redetect() { detectedKinds = ContentDetector.detect(working) }` and call it at the end of `pushState` (after the guard), `setWorking`, and inside `undo`/`redo` when the cursor moved. `refresh` reassigns `self`, so it's covered by `init`.

`PaletteOrdering.swift`:

```swift
import Foundation
import PastefixCore

/// Stable partition of the palette: transforms whose `applicableKinds` intersect the
/// detected kinds first, then everything else, each group in its incoming order.
/// Nothing is hidden; this sits on top of the user's enable/reorder settings.
public enum PaletteOrdering {
    public static func order(_ transformers: [any Transformer], for kinds: Set<ContentKind>) -> [any Transformer] {
        guard !kinds.isEmpty else { return transformers }
        var front: [any Transformer] = []
        var back: [any Transformer] = []
        for t in transformers {
            if let k = t.applicableKinds, !k.isDisjoint(with: kinds) { front.append(t) } else { back.append(t) }
        }
        return front + back
    }
}
```

- [ ] **Step 4: Full suite**

```bash
swift test 2>&1 | tail -1
```

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/PasteDocument.swift Sources/PastefixAppCore/PaletteOrdering.swift Tests/PastefixAppCoreTests/PasteDocumentTests.swift Tests/PastefixAppCoreTests/PaletteOrderingTests.swift
git commit -m "feat(appcore): detectedKinds on PasteDocument and applicable-first PaletteOrdering

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: App wiring — ordered palette and "Detected" badge

**Files:**
- Modify: `Pastefix/Pastefix/AppModel.swift` (`enabledTransformers()`, ~line 49)
- Modify: `Pastefix/Pastefix/PanelView.swift` (`palette`, ~line 60)

**Interfaces:**
- Consumes: `PaletteOrdering.order`, `PasteDocument.detectedKinds`, `ContentKind.displayName`.

- [ ] **Step 1: AppModel** — replace `enabledTransformers()` with:

```swift
    /// Palette list: enabled transforms in the user's order, with those applicable to the
    /// detected content first. Settings uses `allTransformers`, which detection never reorders.
    func enabledTransformers() -> [any Transformer] {
        guard let document else { return [] }
        let enabled = transformers.filter { TransformCoordinator.isEnabled($0, for: document) }
        return PaletteOrdering.order(enabled, for: document.detectedKinds)
    }

    /// "URL", "URL, JSON", or nil when nothing was detected.
    var detectedSummary: String? {
        guard let kinds = document?.detectedKinds, !kinds.isEmpty else { return nil }
        return ContentKind.allCases.filter(kinds.contains).map(\.displayName).joined(separator: ", ")
    }
```

- [ ] **Step 2: PanelView** — inside `palette`, put the badge at the leading edge of the `HStack(spacing: 8)` before the `ForEach`:

```swift
                if let summary = model.detectedSummary {
                    Text("Detected: \(summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .accessibilityLabel("Detected content: \(summary)")
                }
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet 2>&1 | grep -v HotkeyName | grep -E "error|warning" ; echo "build exit ${pipestatus[1]}"
```

Expected: exit 0, no new warnings.

- [ ] **Step 4: Commit**

```bash
git add Pastefix/Pastefix/AppModel.swift Pastefix/Pastefix/PanelView.swift
git commit -m "feat(app): applicable transforms first in the palette, with a Detected badge

Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 5: Manual verification** (human, `Pastefix/launch.sh`):

1. Copy `Read https://www.example.com/page?utm_source=news&id=7 soon.` → summon. Expect the badge `Detected: URL` and the palette starting with **Clean URL Tracking**, **URL → Markdown Link**, then the rest in the usual order.
2. Click **Clean URL Tracking** → `Read https://www.example.com/page?id=7 soon.`
3. Click **URL → Markdown Link** → `Read [Example Domain](https://www.example.com/page?id=7) soon.` (real title fetched). Undo.
4. Copy `https://127.0.0.1:9/nothing` → summon → **URL → Markdown Link** → falls back to `[127.0.0.1/nothing](…)` within ~4 s, no error banner.
5. Copy `{"a": 1}` → summon → badge `Detected: JSON`; palette order unchanged (no JSON transforms yet).
6. Copy `HTTPServerError count` → summon → no badge; click **snake_case** → `http_server_error_count`; Undo; **camelCase** → `httpServerErrorCount`.
7. Settings → Transforms lists the six new transforms in orders 50–73, toggleable; disabling **kebab-case** removes it from the palette; re-enable.

Record results in the PR description.

---

### Task 9: Documentation

**Files:**
- Modify: `README.md` ("Overview" bullets ~39–43, "Built-in Transforms" ~45–52, "Script Metadata" keys/built-in order ~110–111, the app section ~7–20)
- Modify: `AGENTS.md` (layout tree ~66–104, Critical Invariant 8 ~121, Patterns ~126–131, status table ~185–190, project description line 13)

- [ ] **Step 1: README**

- Overview: "Four built-in native transforms" → "Ten built-in native transforms"; add a bullet "**Content detection** — the panel recognises URLs and JSON and lists the transforms that apply to them first".
- Built-in Transforms: append
  ```markdown
  - **Clean URL Tracking:** Removes tracking parameters (`utm_*`, `fbclid`, `gclid`, `si`, `mc_cid`, … ) from every URL in the text; other parameters, fragments, and surrounding text are untouched.
  - **URL → Markdown Link:** Replaces each URL with `[Page Title](url)`. The title is fetched over the network with a 3-second timeout and a 256 KB cap; if that fails the link text is `host/path`. URLs already inside Markdown links are skipped.
  - **camelCase / snake_case / kebab-case / CONSTANT_CASE:** Rewrites each line as one identifier phrase. Splits on separators and camel boundaries (`HTTPServerError` → `http_server_error`), keeps digits with their word (`utf8Decoder`), preserves indentation and non-ASCII letters.
  ```
- In the app section (after the palette description), one paragraph: "**Content detection.** When the buffer contains a URL or is valid JSON, a `Detected: URL` badge appears beside the palette and transforms that apply to that kind are listed first. Nothing is hidden; your enable/reorder settings still apply."
- Script Metadata keys: add `kinds` (comma-separated list of `url`, `json`; a script with `kinds` is listed first when that content is detected; unknown names ignored). Built-in order line: `Rich→Plain (10), Transliterate (20), Wrap (30), Whitespace (40), Clean URL Tracking (50), URL → Markdown Link (60), camelCase (70), snake_case (71), kebab-case (72), CONSTANT_CASE (73)`.

- [ ] **Step 2: AGENTS.md**

- Line 13: "applies text transforms (clean up for IRC/chat, reflow, rich→plain, user scripts)" → add "URL cleanup, Markdown links, case conversion" to the list, and "detects URL/JSON content to surface applicable transforms first".
- Layout tree: under `Sources/PastefixCore/` add
  ```
    Detection/
      ContentKind.swift                 # url | json (+ displayName)
      ContentDetector.swift             # detect(_:) -> Set<ContentKind>, 1 MB guard
      URLFinder.swift                   # internal http(s) link ranges (NSDataDetector)
  ```
  and under `Native/`:
  ```
      URLCleaner.swift                  #   builtin.urlclean     (order 50, kinds [url])
      MarkdownLink.swift                #   builtin.markdownlink (order 60, kinds [url]) + TitleFetcher (the engine's only network access)
      CaseConvert.swift                 #   builtin.case.{camel,snake,kebab,constant} (70–73)
  ```
  and under `Sources/PastefixAppCore/`: `PaletteOrdering.swift  # applicable-first stable partition on top of TransformOverrides`.
- Critical Invariant 8: "Built-ins occupy orders 10/20/30/40" → "Built-ins occupy orders 10/20/30/40/50/60/70–73".
- Patterns: add
  ```
  - **Network in a transform** happens only through an injected protocol (`TitleFetcher`) with a hard timeout and a byte cap, and the transform races it against its own bound so a hung fetcher cannot hang the app. Tests inject a stub; no test opens a socket.
  - **Content kinds:** a transform that is *meant for* a kind sets `applicableKinds`; the palette promotes it, never hides others. Detection heuristics live only in `ContentDetector`.
  ```
- Status table: add `| 3 — Content transforms | URL cleanup, Markdown link, case conversion, detection | 🟡 in review on \`feat/content-transforms\`, PR pending |`.

- [ ] **Step 3: Checks and commit**

```bash
grep -n "Four built-in" README.md; grep -n "10/20/30/40;" AGENTS.md    # both empty
git add README.md AGENTS.md
git commit -m "docs: document content detection and the five new transforms

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: PR

- [ ] **Step 1: Final checks**

```bash
swift test 2>&1 | tail -1
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Release -quiet 2>&1 | grep -E "error" ; git status --short | wc -l
```

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/content-transforms
gh pr create --base main --title "feat: content transforms and detection (Plan 3)" --body "$(cat <<'EOF'
## Summary
- Five built-ins: Clean URL Tracking (50), URL → Markdown Link (60), camelCase/snake_case/kebab-case/CONSTANT_CASE (70–73)
- ContentDetector (URL, JSON) + `Transformer.applicableKinds` + `kinds` script header
- Palette lists applicable transforms first behind a "Detected: …" badge; Settings unchanged
- First network access in the engine, isolated behind `TitleFetcher` with timeout + byte cap; tests offline

Spec: docs/specs/2026-09-20-pastefix-v2-content-transforms.md
Plan: docs/plans/2026-09-20-pastefix-v2-content-transforms.md

## Verification
- `swift test`: <N> tests in <M> suites, all offline
- Manual checklist (Task 8 Step 5): <results>

## Invariants
Critical Invariant 8 extended with the new built-in orders. Invariant 1 respected: CaseConvert keeps non-ASCII letters; URLCleaner touches only URLs.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Replace `<N>`, `<M>`, and `<results>` with the real numbers and outcomes before submitting.

- [ ] **Step 3: After merge** — flip this plan's banner and the AGENTS.md row to ✅ with the merge SHA, then ship it: `scripts/release.sh 1.1.0 --dry-run && scripts/release.sh 1.1.0`.
