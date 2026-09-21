# Pastefix v2 Per-type Quick Actions (Plan 5) — Implementation Plan

> ## ✅ STATUS: COMPLETE — merged to `main` as [PR #30](https://github.com/bnaylor/pastefix/pull/30) (`ba0a829`), 2026-09-20. Closes issue #11; includes the ⌘K Return regression fix.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`. **TDD is required** for every engine and model task (write the failing test, see it fail for the right reason, implement, see it pass). The app target has no unit tests; Task 9 is build + the human checklist in Task 10.

**Goal:** Five new content kinds, fourteen new built-in transforms (JSON actions, encoders/decoders, JWT decode, colour conversions), a `ColorLiteral` type with a swatch in the action bar, and an `invalidInput` error so bad input shows a banner instead of corrupting the buffer.

**Architecture:** Everything but the swatch is pure engine code in `PastefixCore/Native` and `Detection`, tested with fixtures. `TransformCoordinator` learns the new error case. The app adds one computed property and one 14-pt view. Detection stays whole-buffer for kinds whose actions rewrite the whole buffer and presence-based for in-place decoders.

**Tech Stack:** Swift 6 SwiftPM, Foundation (`JSONSerialization`, `Data(base64Encoded:)`, `NSRegularExpression`, `ISO8601DateFormatter`), Swift Testing, one SwiftUI shape.

**Spec:** `docs/specs/2026-09-20-pastefix-v2-quick-actions.md` — read it first.

## Global Constraints

- **Packages stay dependency-free.** Foundation only.
- **Ids / names / orders / categories / kinds:**

  | id | name | order | category | applicableKinds |
  |---|---|---|---|---|
  | `builtin.json.pretty` | JSON Prettify | 80 | Data | `[json]` |
  | `builtin.json.minify` | JSON Minify | 81 | Data | `[json]` |
  | `builtin.json.escape` | Escape as JSON String | 82 | Data | nil |
  | `builtin.base64.encode` | Base64 Encode | 90 | Data | nil |
  | `builtin.base64.decode` | Base64 Decode | 91 | Data | `[base64]` |
  | `builtin.url.encode` | URL Encode | 92 | Data | nil |
  | `builtin.url.decode` | URL Decode | 93 | Data | `[percentEncoded]` |
  | `builtin.html.encode` | HTML Encode | 94 | Data | nil |
  | `builtin.html.decode` | HTML Decode | 95 | Data | `[htmlEntities]` |
  | `builtin.jwt.decode` | Decode JWT | 96 | Data | `[jwt]` |
  | `builtin.color.hex` | Color → CSS Hex | 100 | Colors | `[color]` |
  | `builtin.color.rgb` | Color → CSS rgb() | 101 | Colors | `[color]` |
  | `builtin.color.hsl` | Color → CSS hsl() | 102 | Colors | `[color]` |
  | `builtin.color.swift` | Color → SwiftUI Color | 103 | Colors | `[color]` |

- **Kinds:** `color`, `jwt`, `base64`, `percentEncoded`, `htmlEntities` with display names Color, JWT, Base64, Percent-encoded, HTML entities. Detection rules per the spec; `base64` additionally requires the decoded text to contain no control characters other than tab, newline, carriage return (tightens the spec's "no NUL" so long plain words aren't mis-flagged — Task 11 records this in the spec).
- **`TransformError.invalidInput(String)`** is added; existing cases untouched; `TransformCoordinator.message(for:)` returns the payload verbatim.
- **`TransformCategory.data = "Data"`, `.colors = "Colors"`; `builtinOrder = [layout, characters, urls, case, data, colors]`.**
- **`ColorLiteral`** per the spec: sRGB, components 0…1; parse hex 3/4/6/8, `rgb()/rgba()`, `hsl()/hsla()`, comma and CSS4 syntax; hue normalised to `0..<360`; output forms `cssHex`, `cssRGB`, `cssHSL`, `swiftUI`; alpha omitted when 1; alpha printed with up to 3 decimals trimmed in CSS forms and fixed 3 decimals in the SwiftUI form.
- **JSON:** `.sortedKeys`, `.withoutEscapingSlashes`, fragments allowed; errors → `invalidInput("Not valid JSON: …")`.
- **URL encode** allowed set = RFC 3986 unreserved (`A–Z a–z 0–9 - . _ ~`); **URL decode** rejects any `%` not followed by two hex digits and leaves `+` alone.
- **HTML decode** via a shared `HTMLEntities.decode` (numeric first, then named with `&amp;` last, HTML4 Latin-1 names + common typographic names); unknown entities left verbatim.
- **JWT output:** pretty JSON `{"header":…,"payload":…}` (sorted keys) then `// exp: <ISO8601 UTC> (expired|valid)` when `exp` is numeric, `// iat: …` / `// nbf: …` when present, then `// signature not verified`. Never verifies.
- **Swatch:** 14×14 `RoundedRectangle(cornerRadius: 3)` before the Detected text, only when `AppModel.detectedColor != nil`.
- **Branch:** `feat/quick-actions` in this checkout. Conventional commits with `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #11. **One implementer at a time on the branch** (shared index).

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/PastefixCore/Transformer.swift` | `invalidInput`; `TransformCategory.data/.colors`; `builtinOrder` |
| `Sources/PastefixCore/Detection/ContentKind.swift` | five new cases |
| `Sources/PastefixCore/Detection/HTMLEntities.swift` (new) | shared entity decoder (moved from `MarkdownLink`) |
| `Sources/PastefixCore/Native/MarkdownLink.swift` | `decodeEntities` forwards to `HTMLEntities.decode` |
| `Sources/PastefixAppCore/TransformCoordinator.swift` | message for `invalidInput` |
| `Sources/PastefixCore/Native/ColorLiteral.swift` (new) | parse + format |
| `Sources/PastefixCore/Native/ColorConvert.swift` (new) | four colour transforms |
| `Sources/PastefixCore/Native/JSONActions.swift` (new) | three JSON transforms |
| `Sources/PastefixCore/Native/Encoders.swift` (new) | `Codec`, `Base64Codec`, `Encode`, `Decode` |
| `Sources/PastefixCore/Native/JWTDecode.swift` (new) | `JWTDecoder`, `JWTDecode` |
| `Sources/PastefixCore/Detection/ContentDetector.swift` | five detectors |
| `Sources/PastefixCore/Discovery/TransformerRegistry.swift` | fourteen registrations |
| `Pastefix/Pastefix/AppModel.swift`, `PanelView.swift` | `detectedColor`, swatch |
| Tests: new `ColorLiteralTests`, `ColorConvertTests`, `JSONActionsTests`, `EncodersTests`, `JWTDecodeTests`, `HTMLEntitiesTests`; extend `ContentDetectorTests`, `TransformerRegistryTests`, `TransformCoordinatorTests`, `TitleParsingTests` | |
| `README.md`, `AGENTS.md`, spec | currency |

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/quick-actions && swift test 2>&1 | tail -1` → `191 tests in 25 suites passed`.

---

### Task 1: Foundations — kinds, error case, categories, shared entity decoder

**Files:**
- Modify: `Sources/PastefixCore/Detection/ContentKind.swift`, `Sources/PastefixCore/Transformer.swift`, `Sources/PastefixCore/Native/MarkdownLink.swift`, `Sources/PastefixAppCore/TransformCoordinator.swift`
- Create: `Sources/PastefixCore/Detection/HTMLEntities.swift`
- Test: `Tests/PastefixCoreTests/HTMLEntitiesTests.swift` (new), `Tests/PastefixAppCoreTests/TransformCoordinatorTests.swift`, `Tests/PastefixCoreTests/TransformerRegistryTests.swift` (`builtinOrder` expectation), `Tests/PastefixCoreTests/TitleParsingTests.swift` (unchanged; must still pass via the forwarder)

**Interfaces:**
- Produces: `ContentKind.{color,jwt,base64,percentEncoded,htmlEntities}`; `TransformError.invalidInput(String)`; `TransformCategory.data/.colors`; `enum HTMLEntities { static func decode(_ s: String) -> String }` (internal to `PastefixCore`).

- [ ] **Step 1: Failing tests.**

`Tests/PastefixCoreTests/HTMLEntitiesTests.swift`:
```swift
import Testing
@testable import PastefixCore

@Suite struct HTMLEntitiesTests {
    @Test func basicNamed() { #expect(HTMLEntities.decode("&lt;a&gt; &amp; &quot;q&quot; &apos;s&apos;") == "<a> & \"q\" 's'") }
    @Test func numericAndHex() { #expect(HTMLEntities.decode("&#8212; &#x2014; &#X2014;") == "— — —") }
    @Test func latin1Names() { #expect(HTMLEntities.decode("caf&eacute; &copy; &nbsp;&frac12;") == "café © \u{00A0}½") }
    @Test func typographicNames() { #expect(HTMLEntities.decode("&mdash;&ndash;&hellip;&ldquo;x&rdquo;&euro;&trade;") == "—–…“x”€™") }
    @Test func doubleEncodedDecodesOnce() { #expect(HTMLEntities.decode("&amp;lt;") == "&lt;") }
    @Test func unknownLeftVerbatim() { #expect(HTMLEntities.decode("&bogus; &#xZZ; & alone") == "&bogus; &#xZZ; & alone") }
    @Test func invalidScalarLeftVerbatim() { #expect(HTMLEntities.decode("&#xD800;&#9999999999;") == "&#xD800;&#9999999999;") }
}
```
Append to `TransformCoordinatorTests`:
```swift
    @Test func invalidInputLeavesDocumentAndReportsMessage() async {
        let t = FakeTransformer(id: "bad", name: "Bad", requiresRichInput: false) { _ in
            throw TransformError.invalidInput("Not valid Base64 text")
        }
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("Not valid Base64 text"))
        #expect(updated.working == "hi")
        #expect(updated.canUndo == false)
    }
```
In `TransformerRegistryTests.builtinsCarryTheirCategories` change the `builtinOrder` expectation to `["Layout", "Characters", "URLs", "Case", "Data", "Colors"]`.

- [ ] **Step 2:** `swift test --filter "HTMLEntitiesTests|TransformCoordinatorTests|TransformerRegistryTests"` → compile errors (`HTMLEntities`, `invalidInput` unknown) and the order test fails.

- [ ] **Step 3: Implement.**

`ContentKind.swift`: add cases `color, jwt, base64, percentEncoded, htmlEntities` and display names `"Color"`, `"JWT"`, `"Base64"`, `"Percent-encoded"`, `"HTML entities"`.

`Transformer.swift`: in `TransformError` add `case invalidInput(String)` with a doc comment "Input could not be interpreted by the transform (bad Base64, malformed JSON, not a colour…). The buffer is left unchanged." In `TransformCategory` add `public static let data = "Data"`, `public static let colors = "Colors"`, and `builtinOrder = [layout, characters, urls, `case`, data, colors]`.

`TransformCoordinator.message(for:)`: add `case .invalidInput(let msg): return msg`.

`Detection/HTMLEntities.swift`:
```swift
import Foundation

/// Shared HTML entity decoder (used by HTML Decode and by the Markdown-link title parser).
enum HTMLEntities {
    static func decode(_ s: String) -> String {
        var out = s
        // Numeric references first so "&amp;#39;"-style double-encoding isn't mis-decoded.
        for (pattern, radix) in [("&#[xX]([0-9A-Fa-f]+);", 16), ("&#([0-9]+);", 10)] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            var result = out
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let digits = ns.substring(with: m.range(at: 1))
                guard let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code),
                      let r = Range(m.range, in: result) else { continue }
                result.replaceSubrange(r, with: String(Character(scalar)))
            }
            out = result
        }
        // Named references in a fixed order with "&amp;" LAST so "&amp;lt;" → "&lt;".
        for (name, value) in named { out = out.replacingOccurrences(of: "&\(name);", with: value) }
        return out
    }

    /// HTML4 Latin-1 (U+00A0…U+00FF, in code-point order), common typographic names, then the
    /// five XML names with amp last.
    private static let named: [(String, String)] = {
        let latin1 = ["nbsp","iexcl","cent","pound","curren","yen","brvbar","sect","uml","copy","ordf","laquo","not","shy","reg","macr",
                      "deg","plusmn","sup2","sup3","acute","micro","para","middot","cedil","sup1","ordm","raquo","frac14","frac12","frac34","iquest",
                      "Agrave","Aacute","Acirc","Atilde","Auml","Aring","AElig","Ccedil","Egrave","Eacute","Ecirc","Euml","Igrave","Iacute","Icirc","Iuml",
                      "ETH","Ntilde","Ograve","Oacute","Ocirc","Otilde","Ouml","times","Oslash","Ugrave","Uacute","Ucirc","Uuml","Yacute","THORN","szlig",
                      "agrave","aacute","acirc","atilde","auml","aring","aelig","ccedil","egrave","eacute","ecirc","euml","igrave","iacute","icirc","iuml",
                      "eth","ntilde","ograve","oacute","ocirc","otilde","ouml","divide","oslash","ugrave","uacute","ucirc","uuml","yacute","thorn","yuml"]
        var table: [(String, String)] = latin1.enumerated().map { ($1, String(Character(Unicode.Scalar(0xA0 + UInt32($0))!))) }
        table += [("mdash","—"),("ndash","–"),("hellip","…"),("lsquo","‘"),("rsquo","’"),("ldquo","“"),("rdquo","”"),
                  ("bull","•"),("trade","™"),("euro","€"),("laquo","«"),("raquo","»"),("lt","<"),("gt",">"),("quot","\""),("apos","'")]
        table.append(("amp", "&"))
        return table
    }()
}
```
(`laquo`/`raquo` appear twice — harmless, but remove the duplicates from the typographic list.)

`MarkdownLink.swift`: replace the body of `URLSessionTitleFetcher.decodeEntities` with `HTMLEntities.decode(s)` (keep the static func so `TitleParsingTests` compile).

- [ ] **Step 4:** full `swift test` → green (incl. `TitleParsingTests.entitiesDecoded`, `doubleEncodedAmpersandDecodesOnce`, `uppercaseHexEntity`).
- [ ] **Step 5: Commit** `feat(core): new content kinds, TransformError.invalidInput, Data/Colors categories, shared HTML entity decoder`.

---

### Task 2: `ColorLiteral`

**Files:** Create `Sources/PastefixCore/Native/ColorLiteral.swift`; Test `Tests/PastefixCoreTests/ColorLiteralTests.swift`.

**Interfaces:** `public struct ColorLiteral: Equatable, Sendable { public var red, green, blue, alpha: Double; public init(red:green:blue:alpha:); public static func parse(_:) -> ColorLiteral?; public var cssHex: String; public var cssRGB: String; public var cssHSL: String; public var swiftUI: String; public var hsl: (h: Double, s: Double, l: Double) }`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import PastefixCore

@Suite struct ColorLiteralTests {
    private func p(_ s: String) -> ColorLiteral? { ColorLiteral.parse(s) }
    private func rgb255(_ c: ColorLiteral) -> [Int] { [c.red, c.green, c.blue].map { Int(($0 * 255).rounded()) } }

    @Test func hexForms() {
        #expect(rgb255(p("#fff")!) == [255, 255, 255])
        #expect(p("#ffff")?.alpha == 1)
        #expect(rgb255(p("#FF0080")!) == [255, 0, 128])
        #expect(p("#ff008080")?.alpha == 128.0 / 255.0)
        #expect(rgb255(p("  #abc  ")!) == [170, 187, 204])
    }
    @Test func rgbForms() {
        #expect(rgb255(p("rgb(255, 0, 128)")!) == [255, 0, 128])
        #expect(p("rgb(255 0 128 / 0.5)")?.alpha == 0.5)
        #expect(rgb255(p("rgb(100%, 0%, 50%)")!) == [255, 0, 128])
        #expect(p("rgba(255,0,128,50%)")?.alpha == 0.5)
        #expect(rgb255(p("RGB(300, -5, 12)")!) == [255, 0, 12])   // clamped
    }
    @Test func hslForms() {
        #expect(rgb255(p("hsl(330, 100%, 50%)")!) == [255, 0, 128])
        #expect(rgb255(p("hsl(-30 100% 50%)")!) == [255, 0, 128])   // hue wraps to 330
        #expect(p("hsla(330deg 100% 50% / .25)")?.alpha == 0.25)
        #expect(rgb255(p("hsl(0 0% 50%)")!) == [128, 128, 128])
    }
    @Test func rejects() {
        for bad in ["#ggg", "#12345", "rgb(1,2)", "red", "#fff extra", "hsl(1 2 3 4 5)", "", "rgb()", "rgb(a,b,c)"] {
            #expect(p(bad) == nil, Comment(rawValue: bad))
        }
    }
    @Test func formatting() {
        let c = p("#ff0080")!
        #expect(c.cssHex == "#ff0080")
        #expect(c.cssRGB == "rgb(255 0 128)")
        #expect(c.cssHSL == "hsl(330 100% 50%)")
        #expect(c.swiftUI == "Color(red: 1.000, green: 0.000, blue: 0.502)")
        let t = p("rgb(255 0 128 / 0.5)")!
        #expect(t.cssHex == "#ff008080")
        #expect(t.cssRGB == "rgb(255 0 128 / 0.5)")
        #expect(t.cssHSL == "hsl(330 100% 50% / 0.5)")
        #expect(t.swiftUI == "Color(red: 1.000, green: 0.000, blue: 0.502, opacity: 0.500)")
        #expect(p("rgb(0 0 0 / 0.3333)")!.cssRGB == "rgb(0 0 0 / 0.333)")
    }
    @Test func roundTrips() {
        for hex in ["#000000", "#ffffff", "#ff0080", "#123456", "#0a0b0c", "#80ff00"] {
            let c = p(hex)!
            #expect(p(c.cssRGB)!.cssHex == hex, Comment(rawValue: hex))
            #expect(p(c.cssHSL)!.cssHex == hex, Comment(rawValue: hex))   // integer HSL loses ≤1/255; adjust expectation only if a listed colour provably cannot round-trip
        }
    }
}
```
- [ ] **Step 2:** `swift test --filter ColorLiteralTests` → compile error.
- [ ] **Step 3: Implement**
```swift
import Foundation

/// An sRGB colour parsed from a CSS-style literal. Components are 0…1.
public struct ColorLiteral: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1); self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1); self.alpha = min(max(alpha, 0), 1)
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> ColorLiteral? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("#") { return parseHex(String(t.dropFirst())) }
        guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else { return nil }
        let fn = String(t[..<open])
        let inner = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
        let parts = inner.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let alpha: Double
        if parts.count == 4 { guard let a = alphaValue(parts[3]) else { return nil }; alpha = a } else { alpha = 1 }
        switch fn {
        case "rgb", "rgba":
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            return ColorLiteral(red: r, green: g, blue: b, alpha: alpha)
        case "hsl", "hsla":
            guard let h = hue(parts[0]), let s = percent(parts[1]), let l = percent(parts[2]) else { return nil }
            let (r, g, b) = hslToRGB(h: h, s: s, l: l)
            return ColorLiteral(red: r, green: g, blue: b, alpha: alpha)
        default: return nil
        }
    }

    private static func parseHex(_ h: String) -> ColorLiteral? {
        guard h.allSatisfy(\.isHexDigit) else { return nil }
        let digits: [Character]
        switch h.count {
        case 3, 4: digits = h.flatMap { [$0, $0] }
        case 6, 8: digits = Array(h)
        default: return nil
        }
        func byte(_ i: Int) -> Double { Double(UInt8(String(digits[i..<i + 2]), radix: 16)!) / 255 }
        let a = digits.count == 8 ? byte(6) : 1
        return ColorLiteral(red: byte(0), green: byte(2), blue: byte(4), alpha: a)
    }

    private static func number(_ s: String) -> Double? { Double(s) }
    private static func channel(_ s: String) -> Double? {
        if s.hasSuffix("%") { return number(String(s.dropLast())).map { $0 / 100 } }
        return number(s).map { $0 / 255 }
    }
    private static func percent(_ s: String) -> Double? {
        let core = s.hasSuffix("%") ? String(s.dropLast()) : s
        return number(core).map { min(max($0, 0), 100) / 100 }
    }
    private static func alphaValue(_ s: String) -> Double? {
        if s.hasSuffix("%") { return number(String(s.dropLast())).map { $0 / 100 } }
        return number(s)
    }
    private static func hue(_ s: String) -> Double? {
        let core = s.hasSuffix("deg") ? String(s.dropLast(3)) : s
        guard var h = number(core) else { return nil }
        h = h.truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
        return h
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return (r1 + m, g1 + m, b1 + m)
    }

    // MARK: Formatting

    public var hsl: (h: Double, s: Double, l: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue), d = maxC - minC
        let l = (maxC + minC) / 2
        guard d > 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if maxC == red { h = ((green - blue) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == green { h = (blue - red) / d + 2 }
        else { h = (red - green) / d + 4 }
        h *= 60; if h < 0 { h += 360 }
        return (h, s, l)
    }

    private var r255: Int { Int((red * 255).rounded()) }
    private var g255: Int { Int((green * 255).rounded()) }
    private var b255: Int { Int((blue * 255).rounded()) }
    private var hasAlpha: Bool { alpha < 1 }
    /// "0.5", "0.333", "0.25" — up to 3 decimals, trailing zeros trimmed.
    private var cssAlpha: String {
        var s = String(format: "%.3f", alpha)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public var cssHex: String {
        let base = String(format: "#%02x%02x%02x", r255, g255, b255)
        return hasAlpha ? base + String(format: "%02x", Int((alpha * 255).rounded())) : base
    }
    public var cssRGB: String {
        "rgb(\(r255) \(g255) \(b255)" + (hasAlpha ? " / \(cssAlpha))" : ")")
    }
    public var cssHSL: String {
        let (h, s, l) = hsl
        return "hsl(\(Int(h.rounded())) \(Int((s * 100).rounded()))% \(Int((l * 100).rounded()))%" + (hasAlpha ? " / \(cssAlpha))" : ")")
    }
    public var swiftUI: String {
        let base = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f", red, green, blue)
        return hasAlpha ? base + String(format: ", opacity: %.3f)", alpha) : base + ")"
    }
}
```
- [ ] **Step 4:** filter green. If `roundTrips` fails for a specific listed colour through HSL because integer-percent rounding moves a channel by one, replace that colour in the list with one that round-trips and note it in the report — do not loosen the assertion.
- [ ] **Step 5: Commit** `feat(core): add ColorLiteral (CSS colour parsing and formatting)`.

---

### Task 3: `ColorConvert` transforms

**Files:** Create `Sources/PastefixCore/Native/ColorConvert.swift`; Test `Tests/PastefixCoreTests/ColorConvertTests.swift`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import PastefixCore

@Suite struct ColorConvertTests {
    @Test func outputs() async throws {
        #expect(try await ColorConvert(style: .hex).apply(.init(text: "rgb(255, 0, 128)")) == "#ff0080")
        #expect(try await ColorConvert(style: .rgb).apply(.init(text: "#ff0080")) == "rgb(255 0 128)")
        #expect(try await ColorConvert(style: .hsl).apply(.init(text: "#ff0080")) == "hsl(330 100% 50%)")
        #expect(try await ColorConvert(style: .swift).apply(.init(text: " #FF0080 ")) == "Color(red: 1.000, green: 0.000, blue: 0.502)")
    }
    @Test func invalidInputThrows() async {
        await #expect(throws: TransformError.invalidInput("Not a colour literal")) {
            _ = try await ColorConvert(style: .hex).apply(.init(text: "hello"))
        }
    }
    @Test func metadata() {
        let expect: [(ColorConvert.Style, String, String)] = [
            (.hex, "builtin.color.hex", "Color → CSS Hex"), (.rgb, "builtin.color.rgb", "Color → CSS rgb()"),
            (.hsl, "builtin.color.hsl", "Color → CSS hsl()"), (.swift, "builtin.color.swift", "Color → SwiftUI Color"),
        ]
        for (style, id, name) in expect {
            let t = ColorConvert(style: style)
            #expect(t.id == id); #expect(t.name == name)
            #expect(t.category == TransformCategory.colors); #expect(t.applicableKinds == [.color]); #expect(t.source == .builtin)
        }
    }
}
```
- [ ] **Step 2:** filter → compile error.
- [ ] **Step 3: Implement**
```swift
import Foundation

/// Rewrites a colour literal in another CSS/Swift notation.
public struct ColorConvert: Transformer {
    public enum Style: Sendable { case hex, rgb, hsl, swift }
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.color]
    public let category: String? = TransformCategory.colors
    public let style: Style

    public init(style: Style) {
        self.style = style
        switch style {
        case .hex:   id = "builtin.color.hex";   name = "Color → CSS Hex"
        case .rgb:   id = "builtin.color.rgb";   name = "Color → CSS rgb()"
        case .hsl:   id = "builtin.color.hsl";   name = "Color → CSS hsl()"
        case .swift: id = "builtin.color.swift"; name = "Color → SwiftUI Color"
        }
    }

    public func apply(_ input: TransformInput) async throws -> String {
        guard let c = ColorLiteral.parse(input.text) else { throw TransformError.invalidInput("Not a colour literal") }
        switch style {
        case .hex: return c.cssHex
        case .rgb: return c.cssRGB
        case .hsl: return c.cssHSL
        case .swift: return c.swiftUI
        }
    }
}
```
- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(core): add colour conversion transforms (hex, rgb, hsl, SwiftUI)`.

---

### Task 4: JSON actions

**Files:** Create `Sources/PastefixCore/Native/JSONActions.swift`; Test `Tests/PastefixCoreTests/JSONActionsTests.swift`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import PastefixCore

@Suite struct JSONActionsTests {
    @Test func prettifySortsKeysAndIndents() async throws {
        let out = try await JSONPrettify().apply(.init(text: #"{"b":[1,2,{"z":null,"a":"x/y"}],"a":"é"}"#))
        #expect(out == """
        {
          "a" : "é",
          "b" : [
            1,
            2,
            {
              "a" : "x/y",
              "z" : null
            }
          ]
        }
        """)
    }
    @Test func minify() async throws {
        #expect(try await JSONMinify().apply(.init(text: "{ \"b\" : 1 ,\n \"a\" : [ true ] }")) == #"{"a":[true],"b":1}"#)
    }
    @Test func fragmentsAllowed() async throws {
        #expect(try await JSONMinify().apply(.init(text: " 42 ")) == "42")
    }
    @Test func invalidJSONThrows() async {
        await #expect(throws: TransformError.self) { _ = try await JSONPrettify().apply(.init(text: "{ not json")) }
        do { _ = try await JSONMinify().apply(.init(text: "{ not json")); Issue.record("expected throw") }
        catch let e as TransformError { if case .invalidInput(let m) = e { #expect(m.hasPrefix("Not valid JSON")) } else { Issue.record("wrong case") } }
        catch { Issue.record("wrong error type") }
    }
    @Test func escapeAsJSONString() async throws {
        let out = try await JSONEscape().apply(.init(text: "say \"hi\"\n\ttab \\ slash / é 😀"))
        #expect(out == #""say \"hi\"\n\ttab \\ slash / é 😀""#)
    }
    @Test func metadata() {
        #expect(JSONPrettify().id == "builtin.json.pretty"); #expect(JSONPrettify().applicableKinds == [.json])
        #expect(JSONMinify().id == "builtin.json.minify");   #expect(JSONMinify().applicableKinds == [.json])
        #expect(JSONEscape().id == "builtin.json.escape");   #expect(JSONEscape().applicableKinds == nil)
        for c in [JSONPrettify().category, JSONMinify().category, JSONEscape().category] { #expect(c == TransformCategory.data) }
    }
}
```
Note the prettify expectation uses `JSONSerialization`'s exact pretty format on macOS (`"key" : value`, 2-space indent). If the toolchain's output differs only in that spacing, update the expected literal to the real output and say so in the report — the *content* (sorted keys, unescaped slash, preserved `é`) must hold.

- [ ] **Step 2:** filter → compile error.
- [ ] **Step 3: Implement**
```swift
import Foundation

enum JSONReformat {
    static func parse(_ text: String) throws -> Any {
        guard let data = text.data(using: .utf8) else { throw TransformError.invalidInput("Not valid JSON: not UTF-8") }
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String ?? ns.localizedDescription)
                .split(separator: "\n").first.map(String.init) ?? "parse error"
            throw TransformError.invalidInput("Not valid JSON: \(detail)")
        }
    }
    static func render(_ object: Any, pretty: Bool) throws -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { opts.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: object, options: opts)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct JSONPrettify: Transformer {
    public let id = "builtin.json.pretty", name = "JSON Prettify", requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.json]
    public let category: String? = TransformCategory.data
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String { try JSONReformat.render(JSONReformat.parse(input.text), pretty: true) }
}

public struct JSONMinify: Transformer {
    public let id = "builtin.json.minify", name = "JSON Minify", requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.json]
    public let category: String? = TransformCategory.data
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String { try JSONReformat.render(JSONReformat.parse(input.text), pretty: false) }
}

/// Wraps the whole buffer as one JSON string literal.
public struct JSONEscape: Transformer {
    public let id = "builtin.json.escape", name = "Escape as JSON String", requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = nil
    public let category: String? = TransformCategory.data
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String {
        try JSONReformat.render(input.text, pretty: false)
    }
}
```
(`public let id = "…", name = "…", requiresRichInput = false` on one line is legal Swift; split if the style checker in your head objects.)

- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(core): add JSON Prettify, Minify, and Escape transforms`.

---

### Task 5: Encoders / decoders

**Files:** Create `Sources/PastefixCore/Native/Encoders.swift`; Test `Tests/PastefixCoreTests/EncodersTests.swift`.

**Interfaces:** `public enum Codec: Sendable { case base64, url, html }`; `public struct Encode: Transformer { public init(codec:) }`; `public struct Decode: Transformer { public init(codec:) }`; internal `enum Base64Codec { static func encode(_:) -> String; static func decodeText(_:) -> String?; static func looksLikeBase64(_:) -> Bool }` (Task 7 uses the last).

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import PastefixCore

@Suite struct EncodersTests {
    private func enc(_ c: Codec, _ s: String) async throws -> String { try await Encode(codec: c).apply(.init(text: s)) }
    private func dec(_ c: Codec, _ s: String) async throws -> String { try await Decode(codec: c).apply(.init(text: s)) }

    @Test func base64RoundTrip() async throws {
        #expect(try await enc(.base64, "héllo 😀") == "aMOpbGxvIPCfmIA=")
        #expect(try await dec(.base64, "aMOpbGxvIPCfmIA=") == "héllo 😀")
    }
    @Test func base64DecodeTolerant() async throws {
        #expect(try await dec(.base64, "aMOp\nbGxv IPCf\nmIA") == "héllo 😀")            // whitespace + missing padding
        #expect(try await dec(.base64, "aMOpbGxvIPCfmIA") == "héllo 😀")
        #expect(try await dec(.base64, "PD8-Pz8_") == "<?>???")                              // url-safe alphabet
    }
    @Test func base64DecodeErrors() async {
        await #expect(throws: TransformError.invalidInput("Not valid Base64 text")) { _ = try await dec(.base64, "not base64!!") }
        await #expect(throws: TransformError.invalidInput("Not valid Base64 text")) { _ = try await dec(.base64, "AAAA") }   // decodes to NULs
        await #expect(throws: TransformError.invalidInput("Not valid Base64 text")) { _ = try await dec(.base64, "/////w==") } // invalid UTF-8
    }
    @Test func looksLikeBase64() {
        #expect(Base64Codec.looksLikeBase64("aMOpbGxvIPCfmIA="))
        #expect(!Base64Codec.looksLikeBase64("aMOpbGxv"))                  // < 16 chars
        #expect(!Base64Codec.looksLikeBase64("internationalization"))      // letters, but decodes to junk
        #expect(!Base64Codec.looksLikeBase64("AAAAAAAAAAAAAAAA"))          // NULs
        #expect(Base64Codec.looksLikeBase64("SGVsbG8sIHdvcmxkLiBUaGlzIGlzIHRleHQu"))
    }
    @Test func urlEncodeDecode() async throws {
        #expect(try await enc(.url, "a b&c=d/é~") == "a%20b%26c%3Dd%2F%C3%A9~")
        #expect(try await dec(.url, "a%20b%26c%3Dd%2F%C3%A9+x%E2%80%94") == "a b&c=d/é+x—")
    }
    @Test func urlDecodeErrors() async {
        await #expect(throws: TransformError.invalidInput("Malformed percent-encoding")) { _ = try await dec(.url, "100%ZZ") }
        await #expect(throws: TransformError.invalidInput("Malformed percent-encoding")) { _ = try await dec(.url, "%FF%FE") }   // not UTF-8
    }
    @Test func htmlEncodeDecode() async throws {
        #expect(try await enc(.html, #"<a href="x">Tom & Jerry's</a>"#) == "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;")
        #expect(try await dec(.html, "caf&eacute; &amp;lt; &#8212; &bogus;") == "café &lt; — &bogus;")
    }
    @Test func metadata() {
        let expect: [(Codec, String, String, String, String, Set<ContentKind>?)] = [
            (.base64, "builtin.base64.encode", "Base64 Encode", "builtin.base64.decode", "Base64 Decode", [.base64]),
            (.url, "builtin.url.encode", "URL Encode", "builtin.url.decode", "URL Decode", [.percentEncoded]),
            (.html, "builtin.html.encode", "HTML Encode", "builtin.html.decode", "HTML Decode", [.htmlEntities]),
        ]
        for (codec, eid, ename, did, dname, dkinds) in expect {
            let e = Encode(codec: codec), d = Decode(codec: codec)
            #expect(e.id == eid); #expect(e.name == ename); #expect(e.applicableKinds == nil); #expect(e.category == TransformCategory.data)
            #expect(d.id == did); #expect(d.name == dname); #expect(d.applicableKinds == dkinds); #expect(d.category == TransformCategory.data)
        }
    }
}
```
- [ ] **Step 2:** filter → compile error.
- [ ] **Step 3: Implement**
```swift
import Foundation

public enum Codec: Sendable { case base64, url, html }

enum Base64Codec {
    static func encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// Lenient decode to text: ignores ASCII whitespace, accepts the url-safe alphabet, repairs
    /// padding. nil when it isn't Base64, decodes to invalid UTF-8, or contains NUL.
    static func decodeText(_ s: String) -> String? {
        let compact = s.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let core = compact.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard !core.isEmpty, core.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" }), core.allSatisfy(\.isASCII) else { return nil }
        let padded = core + String(repeating: "=", count: (4 - core.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Detection heuristic: ≥ 16 alphabet chars and decodes to printable text (tab/newline/CR allowed).
    static func looksLikeBase64(_ s: String) -> Bool {
        let compact = s.filter { !$0.isWhitespace }
        guard compact.count >= 16, let text = decodeText(compact) else { return false }
        return text.unicodeScalars.allSatisfy { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0.value >= 0x20 && $0.value != 0x7F }
    }
}

enum URLCodec {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
    static func decode(_ s: String) throws -> String {
        // Every % must introduce two hex digits.
        if let re = try? NSRegularExpression(pattern: "%(?![0-9A-Fa-f]{2})"),
           re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
            throw TransformError.invalidInput("Malformed percent-encoding")
        }
        guard let out = s.removingPercentEncoding else { throw TransformError.invalidInput("Malformed percent-encoding") }
        return out
    }
}

enum HTMLCodec {
    static func encode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}

public struct Encode: Transformer {
    public let codec: Codec
    public let id: String, name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = nil
    public let category: String? = TransformCategory.data
    public init(codec: Codec) {
        self.codec = codec
        switch codec {
        case .base64: id = "builtin.base64.encode"; name = "Base64 Encode"
        case .url:    id = "builtin.url.encode";    name = "URL Encode"
        case .html:   id = "builtin.html.encode";   name = "HTML Encode"
        }
    }
    public func apply(_ input: TransformInput) async throws -> String {
        switch codec {
        case .base64: return Base64Codec.encode(input.text)
        case .url: return URLCodec.encode(input.text)
        case .html: return HTMLCodec.encode(input.text)
        }
    }
}

public struct Decode: Transformer {
    public let codec: Codec
    public let id: String, name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>?
    public let category: String? = TransformCategory.data
    public init(codec: Codec) {
        self.codec = codec
        switch codec {
        case .base64: id = "builtin.base64.decode"; name = "Base64 Decode"; applicableKinds = [.base64]
        case .url:    id = "builtin.url.decode";    name = "URL Decode";    applicableKinds = [.percentEncoded]
        case .html:   id = "builtin.html.decode";   name = "HTML Decode";   applicableKinds = [.htmlEntities]
        }
    }
    public func apply(_ input: TransformInput) async throws -> String {
        switch codec {
        case .base64:
            guard let text = Base64Codec.decodeText(input.text) else { throw TransformError.invalidInput("Not valid Base64 text") }
            return text
        case .url: return try URLCodec.decode(input.text)
        case .html: return HTMLEntities.decode(input.text)
        }
    }
}
```
- [ ] **Step 4:** filter green; full suite green. If `"%FF%FE".removingPercentEncoding` returns a non-nil replacement-character string instead of nil on this toolchain, add an explicit UTF-8 validity check: percent-decode to bytes manually (`%XX` → byte, else UTF-8 bytes of the character) and `String(bytes:encoding:.utf8)`; keep the test.
- [ ] **Step 5: Commit** `feat(core): add Base64, URL, and HTML encode/decode transforms`.

---

### Task 6: JWT decode

**Files:** Create `Sources/PastefixCore/Native/JWTDecode.swift`; Test `Tests/PastefixCoreTests/JWTDecodeTests.swift`.

**Interfaces:** internal `enum JWTDecoder { static func split(_:) -> (header: Data, payload: Data)? }` (Task 7 uses it); `public struct JWTDecode: Transformer`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct JWTDecodeTests {
    private func b64url(_ json: String) -> String {
        Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private func token(header: String = #"{"alg":"HS256","typ":"JWT"}"#, payload: String, sig: String = "sig") -> String {
        "\(b64url(header)).\(b64url(payload)).\(sig)"
    }

    @Test func decodesHeaderAndPayloadWithExpiry() async throws {
        let out = try await JWTDecode().apply(.init(text: token(payload: #"{"sub":"42","exp":1600000000}"#)))
        #expect(out.hasPrefix("{\n"))
        #expect(out.contains("\"alg\" : \"HS256\""))
        #expect(out.contains("\"sub\" : \"42\""))
        #expect(out.contains("// exp: 2020-09-13T12:26:40Z (expired)"))
        #expect(out.hasSuffix("// signature not verified"))
    }
    @Test func futureExpiryIsValid() async throws {
        let out = try await JWTDecode().apply(.init(text: token(payload: #"{"exp":4102444800}"#)))   // 2100-01-01
        #expect(out.contains("// exp: 2100-01-01T00:00:00Z (valid)"))
    }
    @Test func noExpiryNoLine() async throws {
        let out = try await JWTDecode().apply(.init(text: token(payload: #"{"sub":"x","iat":1516239022}"#)))
        #expect(!out.contains("// exp"))
        #expect(out.contains("// iat: 2018-01-18T01:30:22Z"))
    }
    @Test func algNoneWithEmptySignature() async throws {
        let out = try await JWTDecode().apply(.init(text: token(header: #"{"alg":"none"}"#, payload: #"{"a":1}"#, sig: "")))
        #expect(out.contains("\"alg\" : \"none\""))
    }
    @Test func splitRejectsNonJWT() {
        #expect(JWTDecoder.split("a.b") == nil)
        #expect(JWTDecoder.split("\(b64url(#"{"x":1}"#)).\(b64url("{}")).s") == nil)   // header lacks alg
        #expect(JWTDecoder.split("not.base64!.x") == nil)
        #expect(JWTDecoder.split(token(payload: "{}")) != nil)
    }
    @Test func invalidThrows() async {
        await #expect(throws: TransformError.invalidInput("Not a decodable JWT")) { _ = try await JWTDecode().apply(.init(text: "hello.world")) }
    }
    @Test func metadata() {
        let t = JWTDecode()
        #expect(t.id == "builtin.jwt.decode"); #expect(t.name == "Decode JWT")
        #expect(t.applicableKinds == [.jwt]); #expect(t.category == TransformCategory.data)
    }
}
```
- [ ] **Step 2:** filter → compile error.
- [ ] **Step 3: Implement**
```swift
import Foundation

enum JWTDecoder {
    /// Splits and base64url-decodes header and payload. nil unless there are exactly three
    /// dot-separated segments, the first two non-empty, and the header is a JSON object with "alg".
    static func split(_ text: String) -> (header: Data, payload: Data)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              let header = decodeSegment(parts[0]), let payload = decodeSegment(parts[1]),
              let obj = try? JSONSerialization.jsonObject(with: header) as? [String: Any], obj["alg"] != nil
        else { return nil }
        return (header, payload)
    }

    static func decodeSegment(_ s: Substring) -> Data? {
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let std = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: std + String(repeating: "=", count: (4 - std.count % 4) % 4))
    }
}

/// Shows a JWT's header and payload. Never verifies the signature and says so.
public struct JWTDecode: Transformer {
    public let id = "builtin.jwt.decode"
    public let name = "Decode JWT"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.jwt]
    public let category: String? = TransformCategory.data
    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        guard let (h, p) = JWTDecoder.split(input.text),
              let header = try? JSONSerialization.jsonObject(with: h, options: [.fragmentsAllowed]),
              let payload = try? JSONSerialization.jsonObject(with: p, options: [.fragmentsAllowed])
        else { throw TransformError.invalidInput("Not a decodable JWT") }
        let json = try JSONReformat.render(["header": header, "payload": payload], pretty: true)
        var lines = [json]
        if let dict = payload as? [String: Any] {
            let fmt = ISO8601DateFormatter(); fmt.timeZone = TimeZone(identifier: "UTC")
            for key in ["exp", "iat", "nbf"] {
                guard let n = dict[key] as? NSNumber else { continue }
                let date = Date(timeIntervalSince1970: n.doubleValue)
                var line = "// \(key): \(fmt.string(from: date))"
                if key == "exp" { line += date < Date() ? " (expired)" : " (valid)" }
                lines.append(line)
            }
        }
        lines.append("// signature not verified")
        return lines.joined(separator: "\n")
    }
}
```
- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(core): add Decode JWT transform (never verifies signatures)`.

---

### Task 7: Detector rules for the five kinds

**Files:** Modify `Sources/PastefixCore/Detection/ContentDetector.swift`; Test `Tests/PastefixCoreTests/ContentDetectorTests.swift` (append).

- [ ] **Step 1: Failing tests** (append):
```swift
    @Test func colorKind() {
        #expect(ContentDetector.detect("#ff0080") == [.color])
        #expect(ContentDetector.detect(" hsl(120 50% 50%) ") == [.color])
        #expect(ContentDetector.detect("use #fff for white") == [])
    }
    @Test func jwtKindExcludesBase64() {
        let t = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(ContentDetector.detect(t) == [.jwt])
    }
    @Test func base64Kind() {
        #expect(ContentDetector.detect("SGVsbG8sIHdvcmxkLiBUaGlzIGlzIHRleHQu") == [.base64])
        #expect(ContentDetector.detect("SGVsbG8sIHdv\ncmxkLiBUaGlzIGlzIHRleHQu") == [.base64])
        #expect(ContentDetector.detect("aMOpbGxv") == [])                    // too short
        #expect(ContentDetector.detect("internationalization") == [])       // decodes to junk
        #expect(ContentDetector.detect("AAAAAAAAAAAAAAAA") == [])            // NULs
    }
    @Test func percentEncodedKind() {
        #expect(ContentDetector.detect("see a%20b in prose") == [.percentEncoded])
        #expect(ContentDetector.detect("100% sure") == [])
    }
    @Test func htmlEntitiesKind() {
        #expect(ContentDetector.detect("Tom &amp; Jerry") == [.htmlEntities])
        #expect(ContentDetector.detect("caf&eacute; &#8212; &#x2014;") == [.htmlEntities])
        #expect(ContentDetector.detect("Tom & Jerry; fine") == [])
    }
    @Test func decodedJWTOutputIsJSON() async throws {
        let t = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let out = try await JWTDecode().apply(.init(text: t))
        // The trailing comment lines break strict JSON; the detector sees the leading "{" and JSONSerialization fails → not json.
        // That is acceptable: document it. Assert only that it is not mis-detected as jwt/base64.
        #expect(ContentDetector.detect(out).isDisjoint(with: [.jwt, .base64]))
    }
```
(The spec's data-flow paragraph claimed JWT output re-detects as `json`; with the comment lines it does not. Task 11 amends the spec.)

- [ ] **Step 2:** filter → failures.
- [ ] **Step 3: Implement** — in `detect`, after the JSON block:
```swift
        if ColorLiteral.parse(trimmed) != nil { kinds.insert(.color) }
        if JWTDecoder.split(trimmed) != nil { kinds.insert(.jwt) }
        else if Base64Codec.looksLikeBase64(trimmed) { kinds.insert(.base64) }
        if percentRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil { kinds.insert(.percentEncoded) }
        if entityRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil { kinds.insert(.htmlEntities) }
```
with `private static let percentRegex = try! NSRegularExpression(pattern: "%[0-9A-Fa-f]{2}")` and `private static let entityRegex = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]{1,31});")`. Add `import Foundation` if missing.
- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(core): detect color, jwt, base64, percent-encoded, and HTML-entity content`.

---

### Task 8: Register the fourteen transforms

**Files:** `Sources/PastefixCore/Discovery/TransformerRegistry.swift`; `Tests/PastefixCoreTests/TransformerRegistryTests.swift`.

- [ ] **Step 1: Update tests first.** `loadsBuiltinsInOrderWhenNoScripts` id list gains, after `builtin.case.constant`: `"builtin.json.pretty", "builtin.json.minify", "builtin.json.escape", "builtin.base64.encode", "builtin.base64.decode", "builtin.url.encode", "builtin.url.decode", "builtin.html.encode", "builtin.html.decode", "builtin.jwt.decode", "builtin.color.hex", "builtin.color.rgb", "builtin.color.hsl", "builtin.color.swift"`. `toleratesMissingDirectory` → `count == 24`. `builtinsCarryTheirCategories`: add assertions that all ten `Data` ids have category `TransformCategory.data` and the four colour ids `TransformCategory.colors`.
- [ ] **Step 2:** filter → those tests fail.
- [ ] **Step 3: Register** — append to `entries` after the CaseConvert lines:
```swift
            (80, "JSON Prettify", JSONPrettify()),
            (81, "JSON Minify", JSONMinify()),
            (82, "Escape as JSON String", JSONEscape()),
            (90, "Base64 Encode", Encode(codec: .base64)),
            (91, "Base64 Decode", Decode(codec: .base64)),
            (92, "URL Encode", Encode(codec: .url)),
            (93, "URL Decode", Decode(codec: .url)),
            (94, "HTML Encode", Encode(codec: .html)),
            (95, "HTML Decode", Decode(codec: .html)),
            (96, "Decode JWT", JWTDecode()),
            (100, "Color → CSS Hex", ColorConvert(style: .hex)),
            (101, "Color → CSS rgb()", ColorConvert(style: .rgb)),
            (102, "Color → CSS hsl()", ColorConvert(style: .hsl)),
            (103, "Color → SwiftUI Color", ColorConvert(style: .swift)),
```
- [ ] **Step 4:** full suite green.
- [ ] **Step 5: Commit** `feat(core): register JSON, encoder, JWT, and colour transforms at orders 80-103`.

---

### Task 9: Swatch in the action bar

**Files:** `Pastefix/Pastefix/AppModel.swift`, `Pastefix/Pastefix/PanelView.swift`.

- [ ] **Step 1: AppModel** — add after `detectedSummary`:
```swift
    /// The parsed colour when the buffer is a colour literal; drives the action-bar swatch.
    var detectedColor: ColorLiteral? {
        guard let document, document.detectedKinds.contains(.color) else { return nil }
        return ColorLiteral.parse(document.working)
    }
```
- [ ] **Step 2: PanelView.actionBar** — immediately before the `if let summary = model.detectedSummary` block:
```swift
            if let color = model.detectedColor {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Detected colour \(color.cssHex)")
            }
```
- [ ] **Step 3: Build** `xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet 2>&1 | grep -v HotkeyName | grep -E "error|warning"` → empty.
- [ ] **Step 4: Commit** `feat(app): colour swatch beside the Detected badge`.

---

### Task 10: Manual verification (human, `Pastefix/launch.sh`)

- [ ] 1. Copy `#ff0080`, summon → magenta swatch + `Detected: Color`; ⌘K lists the four Color transforms first; ↵ on "Color → CSS hsl()" → `hsl(330 100% 50%)`, swatch unchanged.
- [ ] 2. Copy `hsl(120 50% 50%)`, summon → green swatch. Copy `use #fff for white` → no swatch, no Color badge.
- [ ] 3. Copy the jwt.io sample token, summon → `Detected: JWT`; "Decode JWT" first; output shows header/payload and `// signature not verified`.
- [ ] 4. Copy `see a%20b%26c in prose`, summon → `Detected: Percent-encoded`; URL Decode → `see a b&c in prose`.
- [ ] 5. Copy `Tom &amp; Jerry &eacute;`, summon → `Detected: HTML entities`; HTML Decode → `Tom & Jerry é`.
- [ ] 6. Copy `SGVsbG8sIHdvcmxkLiBUaGlzIGlzIHRleHQu`, summon → `Detected: Base64`; Base64 Decode → `Hello, world. This is text.`
- [ ] 7. Copy `{"b":1,"a":[1,2]}`, summon → JSON Prettify / Minify first; Prettify → sorted, indented; Minify → `{"a":[1,2],"b":1}`.
- [ ] 8. Copy `not json {`, ⌘K, run JSON Prettify → red banner "Not valid JSON: …", buffer unchanged.
- [ ] 9. Sidebar shows DATA and COLORS sections after CASE.

---

### Task 11: Documentation

- [ ] **README:** add the fourteen transforms under "Built-in Transforms" in two groups (Data, Colors), noting sorted-key JSON output, that URL Encode uses RFC 3986 unreserved characters, that Base64 Decode only decodes to text, and that Decode JWT never verifies signatures; add the five kinds to the content-detection paragraph; mention the swatch.
- [ ] **AGENTS.md:** Critical Invariant 2 lists `invalidInput(String)`; Invariant 8's order list adds `80–82/90–96/100–103`; layout tree entries for the six new files and `HTMLEntities.swift`; status row `| 5 — Quick actions | JSON, encoders, JWT, colours, swatch | 🟡 in review on \`feat/quick-actions\`, PR pending |`.
- [ ] **Spec:** amend the data-flow paragraph (JWT output is not re-detected as JSON because of the trailing comment lines) and the base64 rule (printable-text requirement).
- [ ] Commit `docs: document quick-action transforms, new content kinds, and the invalidInput error`.

---

### Task 12: PR

- [ ] `swift test` green; Release build clean; tree clean.
- [ ] `git push -u origin feat/quick-actions`; `gh pr create --base main --title "feat: per-type quick actions — JSON, encoders, JWT, colours (Plan 5)" --body …` with Summary / Verification (Task 10 results) / "Closes #11".
- [ ] **Immediately `git checkout main`.** After merge: flip this banner and the AGENTS.md row to ✅ with the merge SHA. No release unless asked.
