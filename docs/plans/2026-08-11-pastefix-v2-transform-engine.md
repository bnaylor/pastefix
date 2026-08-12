# Pastefix v2 Transform Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** when writing tests, invoke `swift-testing-pro`; when writing async/Process/JSContext code, invoke `swift-concurrency-pro`. Test code below uses the Swift Testing framework (`import Testing`, `@Test`, `#expect`).

**Goal:** Build `PastefixCore`, a standalone, fully unit-tested Swift package providing the Pastefix v2 transform engine: a unified `Transformer` protocol with four native transforms and shell + JavaScript script engines discovered from disk. No UI.

**Architecture:** One `Transformer` protocol with `async throws` apply. Three engine kinds — native Swift structs, a shell runner (spawns a process, stdin→stdout), and a JavaScriptCore runner. A registry scans a scripts directory, maps file extensions to engines, parses magic-comment metadata, and yields an ordered `[any Transformer]` combining built-ins and scripts.

**Tech Stack:** Swift 6, SwiftPM library target, AppKit (`NSAttributedString`), JavaScriptCore, Foundation `Process`, CoreServices `FSEvents`. Tests: Swift Testing.

## Global Constraints

- **Package:** `swift-tools-version: 6.0`; single library product `PastefixCore`; platform floor `.macOS(.v14)`. No external dependencies in this package.
- **Default scripts directory:** `~/.config/pastefix/scripts/` (callers may override; the registry takes the directory as a parameter — it does not hard-code the path).
- **Default transform timeout:** `3` seconds.
- **Default wrap width:** `400` columns (callers pass width in; `WrapReflow` does not hard-code it).
- **Shell contract:** working text on **stdin** → transformed text on **stdout**; non-zero exit → error carrying stderr; run with a minimal scrubbed environment (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`), `cwd` = the script's directory; the script file is executed directly so its shebang is honored.
- **JavaScript contract:** the script defines `function transform(text) { … }`, invoked in a fresh `JSContext` per call; a thrown JS exception or a non-string return → error.
- **Engine by extension:** `.sh`/`.py`/`.pl`/`.rb`/`.zsh` and any other non-`.js` executable → shell; `.js` → JavaScript.
- **Metadata:** magic-comment lines `pastefix: key = value` (keys: `name`, `enabled`, `order`), tolerated behind any of `#`, `//`, `*`, `/*` comment lead-ins, scanned within the first 30 lines. Missing `name` → filename; malformed lines ignored (non-fatal).
- **Timeout semantics:** shell timeout terminates the process (clean); JS timeout abandons the result and returns `.timeout` while the JS thread is left to finish on its own (documented best-effort limitation).

---

## File Structure

```
Package.swift
Sources/PastefixCore/
  Transformer.swift              protocol + TransformInput + TransformerSource + TransformError
  Native/
    WhitespaceCleanup.swift      strip leading, trim trailing, collapse blank lines
    Transliterate.swift          smart-punct normalize + diacritic strip + ASCII-lossy
    WrapReflow.swift             paragraph-aware reflow to width
    RichToPlain.swift            NSAttributedString → plain string
  Scripting/
    ScriptMetadata.swift         magic-comment parser + ScriptMetadata
    ShellRunner.swift            Process spawn, stdin/stdout, timeout, env, cwd
    ShellTransformer.swift       Transformer conformance over ShellRunner
    JSRunner.swift               JSContext eval + transform() call + timeout race
    JSTransformer.swift          Transformer conformance over JSRunner
  Discovery/
    TransformerRegistry.swift    scan dir, extension→engine, merge + order built-ins & scripts
    ScriptWatcher.swift          FSEvents watch → debounced rescan callback
Tests/PastefixCoreTests/
  WhitespaceCleanupTests.swift
  TransliterateTests.swift
  WrapReflowTests.swift
  RichToPlainTests.swift
  ScriptMetadataTests.swift
  ShellRunnerTests.swift
  JSRunnerTests.swift
  TransformerRegistryTests.swift
  ScriptWatcherTests.swift
  Fixtures/                      fixture scripts copied as test resources
```

---

## Task 1: Package scaffold, `Transformer` protocol, and Whitespace Cleanup

**Files:**
- Create: `Package.swift`
- Create: `Sources/PastefixCore/Transformer.swift`
- Create: `Sources/PastefixCore/Native/WhitespaceCleanup.swift`
- Test: `Tests/PastefixCoreTests/WhitespaceCleanupTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol Transformer: Identifiable, Sendable { var id: String { get }; var name: String { get }; var requiresRichInput: Bool { get }; var source: TransformerSource { get }; func apply(_ input: TransformInput) async throws -> String }`
  - `struct TransformInput: Sendable { let text: String; let rich: NSAttributedStringBox? }` where `NSAttributedStringBox` wraps the (non-Sendable) attributed string; use `let text: String; let richRTFD: Data?` instead — see Step 3 (we carry rich content as RTFD `Data`, which is `Sendable`, and reconstruct the attributed string inside `RichToPlain`).
  - `enum TransformerSource: Sendable, Equatable { case builtin; case shell(URL); case javascript(URL) }`
  - `enum TransformError: Error, Equatable { case richInputUnavailable; case timeout; case nonZeroExit(code: Int32, stderr: String); case scriptFailed(String) }`
  - `struct WhitespaceCleanup: Transformer` with `id == "builtin.whitespace"`, `name == "Whitespace Cleanup"`, `requiresRichInput == false`, `source == .builtin`.

- [ ] **Step 1: Scaffold the package**

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PastefixCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PastefixCore", targets: ["PastefixCore"])
    ],
    targets: [
        .target(name: "PastefixCore"),
        .testTarget(
            name: "PastefixCoreTests",
            dependencies: ["PastefixCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
```

Create the `Fixtures` directory so the resource path resolves:

```bash
mkdir -p Sources/PastefixCore/Native Sources/PastefixCore/Scripting Sources/PastefixCore/Discovery Tests/PastefixCoreTests/Fixtures
printf 'placeholder\n' > Tests/PastefixCoreTests/Fixtures/.keep
```

- [ ] **Step 2: Define the protocol and core types**

Create `Sources/PastefixCore/Transformer.swift`:

```swift
import Foundation

/// Content handed to a transform. `text` is the current working buffer.
/// `richRTFD` carries the original clipboard's rich representation as RTFD
/// data (Sendable); only `RichToPlain` reads it.
public struct TransformInput: Sendable {
    public let text: String
    public let richRTFD: Data?

    public init(text: String, richRTFD: Data? = nil) {
        self.text = text
        self.richRTFD = richRTFD
    }
}

public enum TransformerSource: Sendable, Equatable {
    case builtin
    case shell(URL)
    case javascript(URL)
}

public enum TransformError: Error, Equatable {
    case richInputUnavailable
    case timeout
    case nonZeroExit(code: Int32, stderr: String)
    case scriptFailed(String)
}

public protocol Transformer: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    /// True only for transforms that need the original rich clipboard content.
    var requiresRichInput: Bool { get }
    var source: TransformerSource { get }
    func apply(_ input: TransformInput) async throws -> String
}
```

- [ ] **Step 3: Write the failing test**

Create `Tests/PastefixCoreTests/WhitespaceCleanupTests.swift`:

```swift
import Testing
@testable import PastefixCore

@Suite struct WhitespaceCleanupTests {
    let subject = WhitespaceCleanup()

    @Test func stripsLeadingSpacesAndTabs() async throws {
        let out = try await subject.apply(.init(text: "   hello\n\tworld"))
        #expect(out == "hello\nworld")
    }

    @Test func trimsTrailingWhitespace() async throws {
        let out = try await subject.apply(.init(text: "hello   \nworld\t"))
        #expect(out == "hello\nworld")
    }

    @Test func collapsesRepeatedBlankLines() async throws {
        let out = try await subject.apply(.init(text: "a\n\n\n\nb"))
        #expect(out == "a\n\nb")
    }

    @Test func metadata() {
        #expect(subject.id == "builtin.whitespace")
        #expect(subject.requiresRichInput == false)
        #expect(subject.source == .builtin)
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `swift test --filter WhitespaceCleanupTests`
Expected: FAIL — `WhitespaceCleanup` is undefined.

- [ ] **Step 5: Implement `WhitespaceCleanup`**

Create `Sources/PastefixCore/Native/WhitespaceCleanup.swift`:

```swift
import Foundation

public struct WhitespaceCleanup: Transformer {
    public let id = "builtin.whitespace"
    public let name = "Whitespace Cleanup"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        Self.clean(input.text)
    }

    static func clean(_ text: String) -> String {
        var out: [String] = []
        var previousBlank = false
        for rawLine in text.components(separatedBy: "\n") {
            var line = Substring(rawLine)
            while let f = line.first, f == " " || f == "\t" { line = line.dropFirst() }
            while let l = line.last, l == " " || l == "\t" { line = line.dropLast() }
            let blank = line.isEmpty
            if blank && previousBlank { continue }
            out.append(String(line))
            previousBlank = blank
        }
        return out.joined(separator: "\n")
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter WhitespaceCleanupTests`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/PastefixCore/Transformer.swift Sources/PastefixCore/Native/WhitespaceCleanup.swift Tests/PastefixCoreTests/WhitespaceCleanupTests.swift Tests/PastefixCoreTests/Fixtures/.keep
git commit -m "feat(core): scaffold PastefixCore with Transformer protocol and whitespace cleanup"
```

---

## Task 2: Transliterate / strip non-ASCII

**Files:**
- Create: `Sources/PastefixCore/Native/Transliterate.swift`
- Test: `Tests/PastefixCoreTests/TransliterateTests.swift`

**Interfaces:**
- Consumes: `Transformer`, `TransformInput` (Task 1).
- Produces: `struct Transliterate: Transformer` with `id == "builtin.transliterate"`, `name == "Transliterate to ASCII"`, `requiresRichInput == false`, `source == .builtin`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixCoreTests/TransliterateTests.swift`:

```swift
import Testing
@testable import PastefixCore

@Suite struct TransliterateTests {
    let subject = Transliterate()

    @Test func normalizesSmartPunctuation() async throws {
        let out = try await subject.apply(.init(text: "\u{201C}quote\u{201D} \u{2018}x\u{2019} en\u{2013}dash em\u{2014}dash \u{2026}"))
        #expect(out == "\"quote\" 'x' en-dash em--dash ...")
    }

    @Test func stripsDiacritics() async throws {
        let out = try await subject.apply(.init(text: "café résumé naïve"))
        #expect(out == "cafe resume naive")
    }

    @Test func dropsNonASCIIRemnants() async throws {
        // Dingbats and CJK have no ASCII equivalent → removed entirely.
        let out = try await subject.apply(.init(text: "hi \u{2764} 日本 bye"))
        #expect(out == "hi  bye")
    }

    @Test func passesPlainASCIIThrough() async throws {
        let out = try await subject.apply(.init(text: "already ascii"))
        #expect(out == "already ascii")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TransliterateTests`
Expected: FAIL — `Transliterate` is undefined.

- [ ] **Step 3: Implement `Transliterate`**

Create `Sources/PastefixCore/Native/Transliterate.swift`:

```swift
import Foundation

public struct Transliterate: Transformer {
    public let id = "builtin.transliterate"
    public let name = "Transliterate to ASCII"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        Self.transliterate(input.text)
    }

    static let punctuation: [(String, String)] = [
        ("\u{2018}", "'"), ("\u{2019}", "'"),        // ‘ ’
        ("\u{201C}", "\""), ("\u{201D}", "\""),      // “ ”
        ("\u{2013}", "-"), ("\u{2014}", "--"),       // – —
        ("\u{2026}", "..."),                          // …
        ("\u{00A0}", " "),                            // nbsp
    ]

    static func transliterate(_ text: String) -> String {
        var s = text
        for (from, to) in punctuation {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // é → e, ü → u, etc.
        let stripped = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        // Drop anything still outside ASCII (dingbats, CJK, emoji).
        let scalars = stripped.unicodeScalars.filter { $0.isASCII }
        return String(String.UnicodeScalarView(scalars))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TransliterateTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Native/Transliterate.swift Tests/PastefixCoreTests/TransliterateTests.swift
git commit -m "feat(core): add transliterate/strip-non-ASCII transform"
```

---

## Task 3: Wrap & reflow to width

**Files:**
- Create: `Sources/PastefixCore/Native/WrapReflow.swift`
- Test: `Tests/PastefixCoreTests/WrapReflowTests.swift`

**Interfaces:**
- Consumes: `Transformer`, `TransformInput` (Task 1).
- Produces: `struct WrapReflow: Transformer` with a stored `width: Int`, `init(width: Int)`, `id == "builtin.wrapreflow"`, `name == "Wrap & Reflow"`, `requiresRichInput == false`, `source == .builtin`. Paragraphs are separated by blank lines; within a paragraph, existing single newlines are treated as soft breaks and rejoined before wrapping (vim-`gq` behavior). Words longer than `width` overflow their line rather than being broken.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixCoreTests/WrapReflowTests.swift`:

```swift
import Testing
@testable import PastefixCore

@Suite struct WrapReflowTests {
    @Test func wrapsLongLineOnSpaces() async throws {
        let subject = WrapReflow(width: 10)
        let out = try await subject.apply(.init(text: "one two three four five"))
        #expect(out == "one two\nthree four\nfive")
    }

    @Test func reflowsSoftBreaksWithinParagraph() async throws {
        let subject = WrapReflow(width: 20)
        let out = try await subject.apply(.init(text: "hello\nworld\nfoo"))
        #expect(out == "hello world foo")
    }

    @Test func preservesParagraphBreaks() async throws {
        let subject = WrapReflow(width: 20)
        let out = try await subject.apply(.init(text: "para one here\n\npara two here"))
        #expect(out == "para one here\n\npara two here")
    }

    @Test func overflowsWordLongerThanWidth() async throws {
        let subject = WrapReflow(width: 5)
        let out = try await subject.apply(.init(text: "supercalifragilistic ok"))
        #expect(out == "supercalifragilistic\nok")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WrapReflowTests`
Expected: FAIL — `WrapReflow` is undefined.

- [ ] **Step 3: Implement `WrapReflow`**

Create `Sources/PastefixCore/Native/WrapReflow.swift`:

```swift
import Foundation

public struct WrapReflow: Transformer {
    public let id = "builtin.wrapreflow"
    public let name = "Wrap & Reflow"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let width: Int

    public init(width: Int) {
        self.width = width
    }

    public func apply(_ input: TransformInput) async throws -> String {
        Self.reflow(input.text, width: width)
    }

    static func reflow(_ text: String, width: Int) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let wrapped = paragraphs.map { reflowParagraph($0, width: width) }
        return wrapped.joined(separator: "\n\n")
    }

    private static func reflowParagraph(_ para: String, width: Int) -> String {
        let words = para.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count > width {
                lines.append(current)
                current = String(word)
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WrapReflowTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Native/WrapReflow.swift Tests/PastefixCoreTests/WrapReflowTests.swift
git commit -m "feat(core): add wrap & reflow transform"
```

---

## Task 4: Rich → plain text

**Files:**
- Create: `Sources/PastefixCore/Native/RichToPlain.swift`
- Test: `Tests/PastefixCoreTests/RichToPlainTests.swift`

**Interfaces:**
- Consumes: `Transformer`, `TransformInput`, `TransformError` (Task 1).
- Produces: `struct RichToPlain: Transformer` with `id == "builtin.richtoplain"`, `name == "Rich → Plain Text"`, `requiresRichInput == true`, `source == .builtin`. `apply` reconstructs `NSAttributedString` from `input.richRTFD`; if `richRTFD` is nil it throws `TransformError.richInputUnavailable`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixCoreTests/RichToPlainTests.swift`:

```swift
import Testing
import AppKit
@testable import PastefixCore

@Suite struct RichToPlainTests {
    let subject = RichToPlain()

    private func rtfd(_ attributed: NSAttributedString) throws -> Data {
        try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    @Test func flattensStyledTextToPlain() async throws {
        let styled = NSAttributedString(
            string: "Bold Title",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.red]
        )
        let out = try await subject.apply(.init(text: "ignored", richRTFD: try rtfd(styled)))
        #expect(out == "Bold Title")
    }

    @Test func throwsWhenNoRichInput() async throws {
        await #expect(throws: TransformError.richInputUnavailable) {
            try await subject.apply(.init(text: "plain only", richRTFD: nil))
        }
    }

    @Test func metadata() {
        #expect(subject.requiresRichInput == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RichToPlainTests`
Expected: FAIL — `RichToPlain` is undefined.

- [ ] **Step 3: Implement `RichToPlain`**

Create `Sources/PastefixCore/Native/RichToPlain.swift`:

```swift
import Foundation
import AppKit

public struct RichToPlain: Transformer {
    public let id = "builtin.richtoplain"
    public let name = "Rich → Plain Text"
    public let requiresRichInput = true
    public let source: TransformerSource = .builtin

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        guard let data = input.richRTFD else {
            throw TransformError.richInputUnavailable
        }
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        return attributed.string
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter RichToPlainTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Native/RichToPlain.swift Tests/PastefixCoreTests/RichToPlainTests.swift
git commit -m "feat(core): add rich-to-plain transform"
```

---

## Task 5: Magic-comment metadata parser

**Files:**
- Create: `Sources/PastefixCore/Scripting/ScriptMetadata.swift`
- Test: `Tests/PastefixCoreTests/ScriptMetadataTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct ScriptMetadata: Equatable, Sendable { var name: String?; var enabled: Bool; var order: Int? }` with memberwise defaults `name = nil`, `enabled = true`, `order = nil`.
  - `static func ScriptMetadata.parse(_ source: String) -> ScriptMetadata`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixCoreTests/ScriptMetadataTests.swift`:

```swift
import Testing
@testable import PastefixCore

@Suite struct ScriptMetadataTests {
    @Test func parsesShellStyleHeader() {
        let src = """
        #!/bin/sh
        # pastefix: name = Rot13
        # pastefix: enabled = false
        # pastefix: order = 50
        tr a-z n-za-m
        """
        let md = ScriptMetadata.parse(src)
        #expect(md == ScriptMetadata(name: "Rot13", enabled: false, order: 50))
    }

    @Test func parsesBlockCommentStyleHeader() {
        let src = """
        /* pastefix: name = Upper */
        function transform(t) { return t.toUpperCase(); }
        """
        let md = ScriptMetadata.parse(src)
        #expect(md.name == "Upper")
        #expect(md.enabled == true)   // default
        #expect(md.order == nil)
    }

    @Test func defaultsWhenNoMetadata() {
        let md = ScriptMetadata.parse("echo hi")
        #expect(md == ScriptMetadata(name: nil, enabled: true, order: nil))
    }

    @Test func ignoresMalformedAndUnknownKeys() {
        let src = """
        # pastefix: name = Good
        # pastefix: bogus
        # pastefix: unknown = x
        # pastefix: order = notanumber
        """
        let md = ScriptMetadata.parse(src)
        #expect(md.name == "Good")
        #expect(md.order == nil)      // "notanumber" fails Int() → left nil
    }

    @Test func onlyScansFirstThirtyLines() {
        let padding = String(repeating: "x\n", count: 40)
        let md = ScriptMetadata.parse(padding + "# pastefix: name = TooLate")
        #expect(md.name == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ScriptMetadataTests`
Expected: FAIL — `ScriptMetadata` is undefined.

- [ ] **Step 3: Implement `ScriptMetadata`**

Create `Sources/PastefixCore/Scripting/ScriptMetadata.swift`:

```swift
import Foundation

public struct ScriptMetadata: Equatable, Sendable {
    public var name: String?
    public var enabled: Bool
    public var order: Int?

    public init(name: String? = nil, enabled: Bool = true, order: Int? = nil) {
        self.name = name
        self.enabled = enabled
        self.order = order
    }

    public static func parse(_ source: String) -> ScriptMetadata {
        var md = ScriptMetadata()
        let commentLead = CharacterSet(charactersIn: " \t#/*")
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(30) {
            let line = rawLine.trimmingCharacters(in: commentLead)
            guard line.lowercased().hasPrefix("pastefix:") else { continue }
            let body = line.dropFirst("pastefix:".count)
            let parts = body.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]
            switch key {
            case "name": md.name = value
            case "enabled": md.enabled = (value.lowercased() == "true")
            case "order": md.order = Int(value)
            default: break
            }
        }
        return md
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ScriptMetadataTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Scripting/ScriptMetadata.swift Tests/PastefixCoreTests/ScriptMetadataTests.swift
git commit -m "feat(core): add script magic-comment metadata parser"
```

---

## Task 6: Shell runner and shell transformer

**Files:**
- Create: `Sources/PastefixCore/Scripting/ShellRunner.swift`
- Create: `Sources/PastefixCore/Scripting/ShellTransformer.swift`
- Create fixtures: `Tests/PastefixCoreTests/Fixtures/upper.sh`, `Tests/PastefixCoreTests/Fixtures/fail.sh`, `Tests/PastefixCoreTests/Fixtures/sleep.sh`
- Test: `Tests/PastefixCoreTests/ShellRunnerTests.swift`

**Interfaces:**
- Consumes: `TransformError` (Task 1), `ScriptMetadata` (Task 5).
- Produces:
  - `enum ShellRunner { static func run(scriptURL: URL, input: String, timeout: TimeInterval) async throws -> String }` — executes the script file directly (shebang honored), feeds `input` on stdin, returns stdout as UTF-8. Non-zero exit → `TransformError.nonZeroExit(code:stderr:)`; exceeding `timeout` → terminate process, throw `TransformError.timeout`.
  - `struct ShellTransformer: Transformer` — `init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval)`; `id == "shell:" + url.lastPathComponent`; `name` = metadata name or filename; `requiresRichInput == false`; `source == .shell(url)`; `apply` calls `ShellRunner.run`.

- [ ] **Step 1: Create the fixture scripts**

```bash
cat > Tests/PastefixCoreTests/Fixtures/upper.sh <<'EOF'
#!/bin/sh
# pastefix: name = Shout
tr '[:lower:]' '[:upper:]'
EOF
cat > Tests/PastefixCoreTests/Fixtures/fail.sh <<'EOF'
#!/bin/sh
echo "boom" >&2
exit 3
EOF
cat > Tests/PastefixCoreTests/Fixtures/sleep.sh <<'EOF'
#!/bin/sh
sleep 10
EOF
chmod +x Tests/PastefixCoreTests/Fixtures/upper.sh Tests/PastefixCoreTests/Fixtures/fail.sh Tests/PastefixCoreTests/Fixtures/sleep.sh
```

- [ ] **Step 2: Write the failing test**

Create `Tests/PastefixCoreTests/ShellRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct ShellRunnerTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    @Test func pipesStdinToStdout() async throws {
        let url = try fixture("upper.sh")
        let out = try await ShellRunner.run(scriptURL: url, input: "hello", timeout: 5)
        #expect(out.trimmingCharacters(in: .newlines) == "HELLO")
    }

    @Test func nonZeroExitThrowsWithStderr() async throws {
        let url = try fixture("fail.sh")
        await #expect(throws: TransformError.nonZeroExit(code: 3, stderr: "boom\n")) {
            try await ShellRunner.run(scriptURL: url, input: "x", timeout: 5)
        }
    }

    @Test func timeoutThrows() async throws {
        let url = try fixture("sleep.sh")
        await #expect(throws: TransformError.timeout) {
            try await ShellRunner.run(scriptURL: url, input: "x", timeout: 1)
        }
    }

    @Test func shellTransformerUsesMetadataName() {
        let url = URL(fileURLWithPath: "/tmp/foo.sh")
        let t = ShellTransformer(url: url, metadata: ScriptMetadata(name: "Shout"), timeout: 3)
        #expect(t.name == "Shout")
        #expect(t.id == "shell:foo.sh")
        #expect(t.source == .shell(url))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter ShellRunnerTests`
Expected: FAIL — `ShellRunner` is undefined.

- [ ] **Step 4: Implement `ShellRunner`**

Create `Sources/PastefixCore/Scripting/ShellRunner.swift`. Read stdout/stderr fully before `waitUntilExit` to avoid pipe-buffer deadlock; enforce timeout with a watchdog that terminates the process:

```swift
import Foundation

public enum ShellRunner {
    public static func run(scriptURL: URL, input: String, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = scriptURL          // shebang honored by the kernel
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Feed stdin then close so the child sees EOF.
        if let data = input.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Watchdog: terminate on timeout.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        // Drain pipes on background threads to avoid deadlock on large output.
        let outData = await readToEnd(stdoutPipe.fileHandleForReading)
        let errData = await readToEnd(stderrPipe.fileHandleForReading)
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw TransformError.timeout
        }
        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw TransformError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
```

- [ ] **Step 5: Implement `ShellTransformer`**

Create `Sources/PastefixCore/Scripting/ShellTransformer.swift`:

```swift
import Foundation

public struct ShellTransformer: Transformer {
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource
    private let url: URL
    private let timeout: TimeInterval

    public init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval) {
        self.url = url
        self.timeout = timeout
        self.id = "shell:" + url.lastPathComponent
        self.name = metadata.name ?? url.deletingPathExtension().lastPathComponent
        self.source = .shell(url)
    }

    public func apply(_ input: TransformInput) async throws -> String {
        try await ShellRunner.run(scriptURL: url, input: input.text, timeout: timeout)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter ShellRunnerTests`
Expected: PASS (4 tests). The timeout test takes ~1s.

- [ ] **Step 7: Commit**

```bash
git add Sources/PastefixCore/Scripting/ShellRunner.swift Sources/PastefixCore/Scripting/ShellTransformer.swift Tests/PastefixCoreTests/ShellRunnerTests.swift Tests/PastefixCoreTests/Fixtures/upper.sh Tests/PastefixCoreTests/Fixtures/fail.sh Tests/PastefixCoreTests/Fixtures/sleep.sh
git commit -m "feat(core): add shell runner and shell transformer"
```

---

## Task 7: JavaScript runner and JS transformer

**Files:**
- Create: `Sources/PastefixCore/Scripting/JSRunner.swift`
- Create: `Sources/PastefixCore/Scripting/JSTransformer.swift`
- Test: `Tests/PastefixCoreTests/JSRunnerTests.swift`

**Interfaces:**
- Consumes: `TransformError` (Task 1), `ScriptMetadata` (Task 5).
- Produces:
  - `enum JSRunner { static func run(source: String, input: String, timeout: TimeInterval) async throws -> String }` — evaluates `source` in a fresh `JSContext`, calls `transform(input)`, returns the string result. A JS exception or missing/`undefined` `transform`, or a non-string return → `TransformError.scriptFailed(String)`. Exceeding `timeout` → `TransformError.timeout` (result abandoned; the JS thread is left to finish — documented best-effort).
  - `struct JSTransformer: Transformer` — `init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval)`; `id == "js:" + url.lastPathComponent`; `name` = metadata name or filename; `requiresRichInput == false`; `source == .javascript(url)`; `apply` reads the file's contents and calls `JSRunner.run`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixCoreTests/JSRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct JSRunnerTests {
    @Test func callsTransformFunction() async throws {
        let src = "function transform(t){ return t.toUpperCase(); }"
        let out = try await JSRunner.run(source: src, input: "hello", timeout: 5)
        #expect(out == "HELLO")
    }

    @Test func missingTransformThrows() async throws {
        await #expect(throws: TransformError.self) {
            try await JSRunner.run(source: "var x = 1;", input: "hi", timeout: 5)
        }
    }

    @Test func jsExceptionThrows() async throws {
        let src = "function transform(t){ throw new Error('nope'); }"
        await #expect(throws: TransformError.self) {
            try await JSRunner.run(source: src, input: "hi", timeout: 5)
        }
    }

    @Test func runawayScriptTimesOut() async throws {
        let src = "function transform(t){ while(true){} }"
        await #expect(throws: TransformError.timeout) {
            try await JSRunner.run(source: src, input: "hi", timeout: 1)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter JSRunnerTests`
Expected: FAIL — `JSRunner` is undefined.

- [ ] **Step 3: Implement `JSRunner`**

Create `Sources/PastefixCore/Scripting/JSRunner.swift`. Run the JS on a detached global-queue work item and race it against a timeout via a checked continuation guarded by a lock so it resumes exactly once:

```swift
import Foundation
import JavaScriptCore

public enum JSRunner {
    public static func run(source: String, input: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let state = ResumeGuard()

            DispatchQueue.global(qos: .userInitiated).async {
                let result = evaluate(source: source, input: input)
                if state.claim() { continuation.resume(with: result) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if state.claim() { continuation.resume(throwing: TransformError.timeout) }
            }
        }
    }

    private static func evaluate(source: String, input: String) -> Result<String, Error> {
        guard let context = JSContext() else {
            return .failure(TransformError.scriptFailed("could not create JSContext"))
        }
        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown JS exception"
        }
        context.evaluateScript(source)
        if let thrown { return .failure(TransformError.scriptFailed(thrown)) }

        guard let fn = context.objectForKeyedSubscript("transform"), !fn.isUndefined else {
            return .failure(TransformError.scriptFailed("no transform(text) function defined"))
        }
        let value = fn.call(withArguments: [input])
        if let thrown { return .failure(TransformError.scriptFailed(thrown)) }
        guard let value, value.isString else {
            return .failure(TransformError.scriptFailed("transform() did not return a string"))
        }
        return .success(value.toString())
    }
}

/// Ensures a continuation is resumed exactly once across racing closures.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
```

- [ ] **Step 4: Implement `JSTransformer`**

Create `Sources/PastefixCore/Scripting/JSTransformer.swift`:

```swift
import Foundation

public struct JSTransformer: Transformer {
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource
    private let url: URL
    private let timeout: TimeInterval

    public init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval) {
        self.url = url
        self.timeout = timeout
        self.id = "js:" + url.lastPathComponent
        self.name = metadata.name ?? url.deletingPathExtension().lastPathComponent
        self.source = .javascript(url)
    }

    public func apply(_ input: TransformInput) async throws -> String {
        let src = try String(contentsOf: url, encoding: .utf8)
        return try await JSRunner.run(source: src, input: input.text, timeout: timeout)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter JSRunnerTests`
Expected: PASS (4 tests). The runaway-loop test returns in ~1s (the JS thread is abandoned).

- [ ] **Step 6: Commit**

```bash
git add Sources/PastefixCore/Scripting/JSRunner.swift Sources/PastefixCore/Scripting/JSTransformer.swift Tests/PastefixCoreTests/JSRunnerTests.swift
git commit -m "feat(core): add JavaScriptCore runner and JS transformer"
```

---

## Task 8: Transformer registry (discovery + ordering)

**Files:**
- Create: `Sources/PastefixCore/Discovery/TransformerRegistry.swift`
- Test: `Tests/PastefixCoreTests/TransformerRegistryTests.swift`

**Interfaces:**
- Consumes: all built-ins (Tasks 1–4), `ScriptMetadata` (Task 5), `ShellTransformer` (Task 6), `JSTransformer` (Task 7).
- Produces:
  - `struct RegistryConfig: Sendable { var scriptsDirectory: URL; var wrapWidth: Int; var timeout: TimeInterval; init(scriptsDirectory:, wrapWidth: Int = 400, timeout: TimeInterval = 3) }`.
  - `struct TransformerRegistry { let config: RegistryConfig; init(config:); func load() -> [any Transformer] }`.
  - `load()` returns enabled transforms only, ordered by ascending `order` (built-ins default to their fixed positions 10/20/30/40; scripts use their metadata `order`, defaulting to 1000), ties broken by `name`. Built-ins: RichToPlain(10), Transliterate(20), WrapReflow(30, width from config), WhitespaceCleanup(40). Files with extension `.js` → `JSTransformer`; every other regular file that is not hidden → `ShellTransformer`. A script whose metadata `enabled == false` is excluded.

- [ ] **Step 1: Write the failing test**

Create `Tests/PastefixCoreTests/TransformerRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct TransformerRegistryTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pfx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadsBuiltinsInOrderWhenNoScripts() throws {
        let dir = try makeTempDir()
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 400))
        let ids = reg.load().map(\.id)
        #expect(ids == ["builtin.richtoplain", "builtin.transliterate", "builtin.wrapreflow", "builtin.whitespace"])
    }

    @Test func discoversAndOrdersScriptsAmongBuiltins() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = Early\n# pastefix: order = 5\ncat".write(
            to: dir.appendingPathComponent("early.sh"), atomically: true, encoding: .utf8)
        try "/* pastefix: name = LateJS */\nfunction transform(t){return t;}".write(
            to: dir.appendingPathComponent("late.js"), atomically: true, encoding: .utf8)

        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        let names = reg.load().map(\.name)
        // Early(order 5) precedes built-ins (10-40); LateJS(order 1000 default) last.
        #expect(names.first == "Early")
        #expect(names.last == "LateJS")
    }

    @Test func excludesDisabledScripts() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = Off\n# pastefix: enabled = false\ncat".write(
            to: dir.appendingPathComponent("off.sh"), atomically: true, encoding: .utf8)
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        #expect(reg.load().contains { $0.name == "Off" } == false)
    }

    @Test func toleratesMissingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let reg = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80))
        #expect(reg.load().count == 4)   // built-ins only, no crash
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TransformerRegistryTests`
Expected: FAIL — `TransformerRegistry` is undefined.

- [ ] **Step 3: Implement `TransformerRegistry`**

Create `Sources/PastefixCore/Discovery/TransformerRegistry.swift`:

```swift
import Foundation

public struct RegistryConfig: Sendable {
    public var scriptsDirectory: URL
    public var wrapWidth: Int
    public var timeout: TimeInterval

    public init(scriptsDirectory: URL, wrapWidth: Int = 400, timeout: TimeInterval = 3) {
        self.scriptsDirectory = scriptsDirectory
        self.wrapWidth = wrapWidth
        self.timeout = timeout
    }
}

public struct TransformerRegistry {
    public let config: RegistryConfig

    public init(config: RegistryConfig) {
        self.config = config
    }

    private static let scriptDefaultOrder = 1000

    public func load() -> [any Transformer] {
        var entries: [(order: Int, name: String, transformer: any Transformer)] = [
            (10, "Rich → Plain Text", RichToPlain()),
            (20, "Transliterate to ASCII", Transliterate()),
            (30, "Wrap & Reflow", WrapReflow(width: config.wrapWidth)),
            (40, "Whitespace Cleanup", WhitespaceCleanup()),
        ]

        for url in discoverScriptFiles() {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let md = ScriptMetadata.parse(source)
            guard md.enabled else { continue }
            let order = md.order ?? Self.scriptDefaultOrder
            let transformer: any Transformer =
                url.pathExtension.lowercased() == "js"
                ? JSTransformer(url: url, metadata: md, timeout: config.timeout)
                : ShellTransformer(url: url, metadata: md, timeout: config.timeout)
            entries.append((order, transformer.name, transformer))
        }

        return entries
            .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
            .map(\.transformer)
    }

    private func discoverScriptFiles() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: config.scriptsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TransformerRegistryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Discovery/TransformerRegistry.swift Tests/PastefixCoreTests/TransformerRegistryTests.swift
git commit -m "feat(core): add transformer registry with discovery and ordering"
```

---

## Task 9: Script directory watcher (FSEvents)

**Files:**
- Create: `Sources/PastefixCore/Discovery/ScriptWatcher.swift`
- Test: `Tests/PastefixCoreTests/ScriptWatcherTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (independent utility; callers wire it to `TransformerRegistry.load()`).
- Produces:
  - `final class Debouncer: @unchecked Sendable { init(delay: TimeInterval, queue: DispatchQueue = .main); func schedule(_ work: @escaping @Sendable () -> Void) }` — coalesces rapid calls, firing `work` once `delay` after the last call.
  - `final class ScriptWatcher { init(directory: URL, debounce: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void); func start(); func stop() }` — starts an `FSEventStream` on `directory`; on file events it fires `onChange` through the debouncer. `deinit` calls `stop()`.

The `Debouncer` is unit-tested (deterministic). The `ScriptWatcher` FSEvents integration is verified manually (documented in Step 5) because real filesystem-event timing is not deterministic in unit tests.

- [ ] **Step 1: Write the failing test (Debouncer)**

Create `Tests/PastefixCoreTests/ScriptWatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct ScriptWatcherTests {
    @Test func debouncerFiresOnceAfterBurst() async throws {
        let counter = Counter()
        let debouncer = Debouncer(delay: 0.1, queue: .global())
        for _ in 0..<5 { debouncer.schedule { counter.increment() } }
        try await Task.sleep(nanoseconds: 300_000_000)   // 0.3s > delay
        #expect(counter.value == 1)
    }

    @Test func debouncerFiresAgainAfterQuietPeriod() async throws {
        let counter = Counter()
        let debouncer = Debouncer(delay: 0.1, queue: .global())
        debouncer.schedule { counter.increment() }
        try await Task.sleep(nanoseconds: 250_000_000)
        debouncer.schedule { counter.increment() }
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(counter.value == 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ScriptWatcherTests`
Expected: FAIL — `Debouncer` is undefined.

- [ ] **Step 3: Implement `Debouncer` and `ScriptWatcher`**

Create `Sources/PastefixCore/Discovery/ScriptWatcher.swift`:

```swift
import Foundation
import CoreServices

public final class Debouncer: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    public init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    public func schedule(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        pending?.cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

public final class ScriptWatcher {
    private let directory: URL
    private let onChange: @Sendable () -> Void
    private let debouncer: Debouncer
    private var stream: FSEventStreamRef?

    public init(directory: URL, debounce: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.onChange = onChange
        self.debouncer = Debouncer(delay: debounce, queue: .main)
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScriptWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.debouncer.schedule { watcher.onChange() }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let paths = [directory.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ScriptWatcherTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Manual verification of FSEvents integration**

Add this to a scratch executable or a temporary `@main` and confirm the callback fires (this is not a unit test — FSEvents timing is non-deterministic):

```swift
let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/pastefix/scripts")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let watcher = ScriptWatcher(directory: dir) { print("scripts changed") }
watcher.start()
// touch a file in that directory; expect "scripts changed" within ~0.5s.
RunLoop.main.run()
```

Confirm "scripts changed" prints once per edit burst, then remove the scratch code.

- [ ] **Step 6: Commit**

```bash
git add Sources/PastefixCore/Discovery/ScriptWatcher.swift Tests/PastefixCoreTests/ScriptWatcherTests.swift
git commit -m "feat(core): add debounced FSEvents script watcher"
```

---

## Task 10: Full suite green + README

**Files:**
- Create: `README.md` (package-level, in the package root or `Sources/PastefixCore/` — follow repo convention)
- Modify: none

**Interfaces:** none.

- [ ] **Step 1: Run the entire suite**

Run: `swift test`
Expected: PASS — all suites (Whitespace, Transliterate, WrapReflow, RichToPlain, ScriptMetadata, ShellRunner, JSRunner, TransformerRegistry, ScriptWatcher).

- [ ] **Step 2: Write the package README**

Document (per `AGENTS.md` docs-currency rule): what `PastefixCore` is, the four built-in transforms, the shell contract (stdin→stdout, non-zero exit = error, minimal env), the JS contract (`function transform(text)`), the magic-comment metadata keys (`name`, `enabled`, `order`), the `~/.config/pastefix/scripts/` default location, and the JS-timeout best-effort caveat. Include one shell and one JS example script.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(core): document PastefixCore engine, contracts, and script metadata"
```

---

## Self-Review

**Spec coverage** (against `docs/specs/2026-08-11-pastefix-v2-foundation-pipeline.md`):

- Unified `Transformer` protocol with native/shell/JS engines → Tasks 1, 6, 7. ✓
- Four native transforms (rich→plain, transliterate, wrap/reflow, whitespace) → Tasks 1–4. ✓
- `TransformInput` carrying rich content → Task 1 (as RTFD `Data` for Sendability; `RichToPlain` reconstructs). ✓
- Magic-comment metadata (`name`/`enabled`/`order`, tolerant, first-30-lines) → Task 5. ✓
- Shell contract (stdin→stdout, non-zero=error+stderr, minimal env, cwd=scripts dir, shebang honored, timeout kills process) → Task 6. ✓
- JS contract (`function transform(text)`, fresh context, exception→error, timeout best-effort) → Task 7. ✓
- Discovery (extension→engine, enabled/order merge of built-ins + scripts, tolerant of missing dir) → Task 8. ✓
- FSEvents watch with debounce → Task 9. ✓
- Uniform failure model (timeout / non-zero / exception → typed error, never corrupts state) → `TransformError` (Task 1) surfaced by Tasks 6–8. The "no-op on the document, inline banner, undo untouched" behavior is a *UI* responsibility deferred to Plan 2; the engine's contract is only to throw a typed error, which these tasks satisfy. ✓
- **Not in this plan (correctly, per spec scope):** app shell, `MenuBarExtra`, `NSPanel`, editor, `PasteDocument`/history/undo, Settings, KeyboardShortcuts, Sparkle → Plan 2.

**Placeholder scan:** no TBD/TODO; every code and test step contains real content. The `.keep` fixture file exists only to make the `Fixtures` resource directory valid before Task 6 adds real fixtures. ✓

**Type consistency:** `Transformer`, `TransformInput(text:richRTFD:)`, `TransformerSource` (`.builtin`/`.shell(URL)`/`.javascript(URL)`), `TransformError` (`.richInputUnavailable`/`.timeout`/`.nonZeroExit(code:stderr:)`/`.scriptFailed(String)`), `ScriptMetadata(name:enabled:order:)`, `ShellRunner.run(scriptURL:input:timeout:)`, `JSRunner.run(source:input:timeout:)`, `ShellTransformer`/`JSTransformer(url:metadata:timeout:)`, `RegistryConfig(scriptsDirectory:wrapWidth:timeout:)`, `TransformerRegistry.load() -> [any Transformer]` are used consistently across tasks. Built-in ids (`builtin.richtoplain`/`builtin.transliterate`/`builtin.wrapreflow`/`builtin.whitespace`) match between their defining task and the registry-order test in Task 8. ✓
