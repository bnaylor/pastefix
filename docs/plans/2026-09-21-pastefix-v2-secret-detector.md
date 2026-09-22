# Pastefix v2 Secret Detector & Redaction (Plan 11) — Implementation Plan

> ## 🟡 STATUS: IN PROGRESS — branch `feat/secret-detector`; Tasks 0–4 done, Task 5 (docs) in progress, Task 6 (GUI pass + PR) remaining.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; SwiftUI (Task 4) → `swiftui-pro`. **TDD is required** for every package task. **One implementer at a time on the branch.** GUI passes are run by the controller only, with the user's permission.

**Goal:** Detect credentials in the working buffer with bounded patterns, show an orange badge that selects matches, offer a Redact Secrets transform, and flag history items that carry secrets. Save is unchanged.

**Architecture:** `PastefixCore` gains `SecretDetector` (kinds, bounded regex scan, entropy, non-overlapping matches), `SecretRedactor`, `RedactSecrets`, `ContentKind.secret`, and a Privacy category. `PastefixAppCore` pins `secretMatches` on the document at discrete events and persists `containsSecret` on history items. The app shows the badge (click selects the next match via the editor selection binding), omits `.secret` from the Detected badge, and marks overlay rows.

**Tech Stack:** Swift 6 SwiftPM (macOS 14+), `NSRegularExpression`, Swift Testing; SwiftUI `TextEditor(text:selection:)` (macOS 15+; app target 26.3).

**Spec:** `docs/specs/2026-09-21-pastefix-v2-secret-detector.md` — read it first.

## Global Constraints

- **Patterns verbatim from the spec's Decisions table**; every quantifier bounded; the private-key block body capped at 8 192 chars; the 1 MB guard applies before any scan.
- **Generic assignment** fires only when the key name matches AND the value's Shannon entropy ≥ 3.5 bits/char (value length 16…256).
- **Matches are sorted by location and non-overlapping** (earliest start wins; on equal start the longer wins).
- **Redaction tokens:** `[REDACTED <slug>]`; `passwordInURL` replaces only the password with `[REDACTED]`; redaction is idempotent.
- **Ids/orders:** `builtin.redactsecrets`, "Redact Secrets", order 110, `TransformCategory.privacy` ("Privacy", appended last to `builtinOrder`), `applicableKinds: [.secret]`.
- **UI:** the Detected badge never lists "Secrets"; the orange badge shows `"N secret"`/`"N secrets"`; clicking re-scans the live buffer and selects the next match (cycling); badge hidden while an overlay is open.
- **History:** `containsSecret` computed from the item's text at `record`/`pinText`; legacy indexes decode `false`; images never set it.
- **Branch:** `feat/secret-detector`. Conventional commits + `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #13. `main` is protected.

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/secret-detector && swift test 2>&1 | tail -1` → `373 tests in 45 suites passed`.

---

### Task 1: `SecretDetector`, `SecretRedactor`, kind, category (Core, TDD)

**Files:** Create `Sources/PastefixCore/Detection/SecretDetector.swift`; Modify `Detection/ContentKind.swift`, `Detection/ContentDetector.swift`, `Transformer.swift`; Tests `Tests/PastefixCoreTests/SecretDetectorTests.swift`, `SecretRedactorTests.swift` (new), `ContentDetectorTests.swift` (extend).

- [ ] **Step 1: Failing tests**
```swift
// SecretDetectorTests.swift
import Testing
@testable import PastefixCore

@Suite struct SecretDetectorTests {
    func kinds(_ s: String) -> [SecretKind] { SecretDetector.scan(s).map(\.kind) }
    func texts(_ s: String) -> [String] { SecretDetector.scan(s).map { String(s[$0.range]) } }

    @Test func awsAccessKey() {
        #expect(kinds("key AKIAIOSFODNN7EXAMPLE here") == [.awsAccessKey])
        #expect(kinds("AKIAIOSFODNN7EXAMPL") == [])                       // 15 chars
        #expect(kinds("xAKIAIOSFODNN7EXAMPLEx") == [])                    // no word boundary
    }
    @Test func awsSecretKey() {
        #expect(kinds("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY") == [.awsSecretKey])
        #expect(kinds("aws_secret_access_key = short") == [])
    }
    @Test func githubTokens() {
        #expect(kinds("ghp_" + String(repeating: "a", count: 36)) == [.githubToken])
        #expect(kinds("ghp_" + String(repeating: "a", count: 35)) == [])
        #expect(kinds("github_pat_" + String(repeating: "A1", count: 15)) == [.githubToken])
    }
    @Test func openAIKey() {
        #expect(kinds("OPENAI=sk-proj-" + String(repeating: "x9", count: 20)) == [.openAIKey])
        #expect(kinds("my task-list is sk-ipped") == [])
    }
    @Test func slackStripeGoogle() {
        #expect(kinds("xoxb-1234567890-abcdefghij") == [.slackToken])
        #expect(kinds("sk_live_" + String(repeating: "Ab1", count: 8)) == [.stripeKey])
        #expect(kinds("AIza" + String(repeating: "q", count: 35)) == [.googleAPIKey])
        #expect(kinds("AIza" + String(repeating: "q", count: 34)) == [])
    }
    @Test func privateKeyBlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nABC\n-----END RSA PRIVATE KEY-----"
        #expect(kinds(pem) == [.privateKey])
        #expect(texts("x \(pem) y") == [pem])
        #expect(kinds("-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----") == [])
    }
    @Test func jwt() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(kinds("Bearer \(jwt)") == [.jwt])
        #expect(kinds("a.b.c") == [])
    }
    @Test func passwordInURL() {
        let m = SecretDetector.scan("db: postgres://admin:s3cr3tPass@db.example.com:5432/app")
        #expect(m.map(\.kind) == [.passwordInURL])
        #expect(texts("postgres://admin:s3cr3tPass@db.example.com/app") == ["s3cr3tPass"])
        #expect(kinds("https://example.com/a:b@c") == [])     // no userinfo before host
    }
    @Test func genericAssignmentNeedsEntropy() {
        #expect(kinds("password=changeme-changeme") == [])
        #expect(kinds("api_key: \"9f8e7d6c5b4a39281706f5e4d3c2b1a0\"") == [.genericAssignment])
        #expect(kinds("token = null") == [])
        #expect(kinds("secret=aaaaaaaaaaaaaaaaaaaa") == [])
    }
    @Test func matchesAreSortedAndNonOverlapping() {
        let s = "AKIAIOSFODNN7EXAMPLE then api_key=9f8e7d6c5b4a39281706f5e4d3c2b1a0"
        let m = SecretDetector.scan(s)
        #expect(m.map(\.kind) == [.awsAccessKey, .genericAssignment])
        #expect(m[0].range.upperBound <= m[1].range.lowerBound)
    }
    @Test func boundedCost() {
        let line = String(repeating: "sk-abc ", count: 9_000)          // ~63 KB of near-misses
        let clock = ContinuousClock(); let t = clock.measure { _ = SecretDetector.scan(line) }
        #expect(t < .milliseconds(150))
        #expect(SecretDetector.scan(String(repeating: "a", count: SecretDetector.maxBytes + 1)).isEmpty)
    }
    @Test func entropy() {
        #expect(SecretDetector.entropy("aaaaaaaa") == 0)
        #expect(SecretDetector.entropy("9f8e7d6c5b4a39281706f5e4d3c2b1a0") > 3.5)
    }
}

// SecretRedactorTests.swift
import Testing
@testable import PastefixCore

@Suite struct SecretRedactorTests {
    func redact(_ s: String) -> String { SecretRedactor.redact(s, matches: SecretDetector.scan(s)) }
    @Test func tokensPerKind() {
        #expect(redact("k=AKIAIOSFODNN7EXAMPLE!") == "k=[REDACTED aws-access-key]!")
        #expect(redact("ghp_" + String(repeating: "a", count: 36)) == "[REDACTED github-token]")
    }
    @Test func urlKeepsUserAndHost() {
        #expect(redact("postgres://admin:s3cr3tPass@db.example.com/app") == "postgres://admin:[REDACTED]@db.example.com/app")
    }
    @Test func idempotent() {
        let once = redact("api_key: 9f8e7d6c5b4a39281706f5e4d3c2b1a0 and AKIAIOSFODNN7EXAMPLE")
        #expect(redact(once) == once && once == "api_key: [REDACTED credential] and [REDACTED aws-access-key]")
    }
    @Test func preservesSurroundingText() {
        let pem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
        #expect(redact("before\n\(pem)\nafter") == "before\n[REDACTED private-key]\nafter")
    }
}
```
Append to `ContentDetectorTests`:
```swift
    @Test func secretKindCoexistsWithURL() {
        let k = ContentDetector.detect("see https://example.com and AKIAIOSFODNN7EXAMPLE")
        #expect(k.contains(.secret) && k.contains(.url) && ContentKind.secret.displayName == "Secrets")
    }
```
- [ ] **Step 2:** `swift test --filter "SecretDetectorTests|SecretRedactorTests|ContentDetectorTests"` → compile errors.
- [ ] **Step 3: Implement** `SecretDetector.swift`:
```swift
import Foundation

public enum SecretKind: String, CaseIterable, Sendable {
    case awsAccessKey, awsSecretKey, githubToken, openAIKey, slackToken, stripeKey, googleAPIKey, privateKey, jwt, passwordInURL, genericAssignment
    public var displayName: String {
        switch self {
        case .awsAccessKey: "AWS access key"; case .awsSecretKey: "AWS secret key"; case .githubToken: "GitHub token"
        case .openAIKey: "OpenAI key"; case .slackToken: "Slack token"; case .stripeKey: "Stripe key"; case .googleAPIKey: "Google API key"
        case .privateKey: "private key"; case .jwt: "JWT"; case .passwordInURL: "password in URL"; case .genericAssignment: "credential assignment"
        }
    }
    public var slug: String {
        switch self {
        case .awsAccessKey: "aws-access-key"; case .awsSecretKey: "aws-secret-key"; case .githubToken: "github-token"
        case .openAIKey: "openai-key"; case .slackToken: "slack-token"; case .stripeKey: "stripe-key"; case .googleAPIKey: "google-api-key"
        case .privateKey: "private-key"; case .jwt: "jwt"; case .passwordInURL: "password"; case .genericAssignment: "credential"
        }
    }
}

public struct SecretMatch: Sendable, Equatable {
    public let kind: SecretKind
    /// The token to redact. For `.passwordInURL` this is the password only.
    public let range: Range<String.Index>
}

/// Bounded-regex credential scanner. Every quantifier is bounded (Plan 8 lesson); the generic
/// key=value rule additionally requires a high-entropy value so `password=changeme` stays quiet.
public enum SecretDetector {
    public static let maxBytes = 1_048_576
    static let minEntropy = 3.5

    private struct Rule { let kind: SecretKind; let regex: NSRegularExpression; let group: Int; let needsEntropy: Bool }
    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let rules: [Rule] = [
        Rule(kind: .awsAccessKey, regex: rx(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .awsSecretKey, regex: rx(#"aws[_-]?secret[_-]?(?:access[_-]?)?key\W{0,5}([A-Za-z0-9/+=]{40})"#, .caseInsensitive), group: 1, needsEntropy: false),
        Rule(kind: .githubToken, regex: rx(#"\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,255})\b"#), group: 0, needsEntropy: false),
        Rule(kind: .openAIKey, regex: rx(#"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,200}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .slackToken, regex: rx(#"\bxox[abprs]-[A-Za-z0-9-]{10,200}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .stripeKey, regex: rx(#"\b(?:sk|rk)_live_[A-Za-z0-9]{16,200}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .googleAPIKey, regex: rx(#"\bAIza[0-9A-Za-z_-]{35}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .privateKey, regex: rx(#"-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----[\s\S]{0,8192}?-----END [A-Z ]{0,20}PRIVATE KEY-----"#), group: 0, needsEntropy: false),
        Rule(kind: .jwt, regex: rx(#"\b[A-Za-z0-9_-]{8,2048}\.[A-Za-z0-9_-]{8,4096}\.[A-Za-z0-9_-]{8,2048}\b"#), group: 0, needsEntropy: false),
        Rule(kind: .passwordInURL, regex: rx(#"\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@]{1,64}:([^\s/@]{1,128})@"#, .caseInsensitive), group: 1, needsEntropy: false),
        Rule(kind: .genericAssignment, regex: rx(#"\b(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?token|client[_-]?secret)\b\s*[:=]\s*["']?([A-Za-z0-9_\-+/=.]{16,256})["']?"#, .caseInsensitive), group: 1, needsEntropy: true),
    ]

    public static func scan(_ text: String) -> [SecretMatch] {
        guard text.utf8.count <= maxBytes, !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [(NSRange, SecretKind)] = []
        for rule in rules {
            for m in rule.regex.matches(in: text, range: full) {
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound else { continue }
                let token = ns.substring(with: r)
                if rule.kind == .jwt, JWTDecoder.split(token) == nil { continue }
                if rule.needsEntropy, entropy(token) < minEntropy { continue }
                found.append((r, rule.kind))
            }
        }
        found.sort { a, b in a.0.location != b.0.location ? a.0.location < b.0.location : a.0.length > b.0.length }
        var out: [SecretMatch] = []; var cursor = 0
        for (r, kind) in found where r.location >= cursor {
            guard let range = Range(r, in: text) else { continue }
            out.append(SecretMatch(kind: kind, range: range)); cursor = NSMaxRange(r)
        }
        return out
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in let p = Double(c) / n; return acc - p * log2(p) }
    }
}

public enum SecretRedactor {
    public static func redact(_ text: String, matches: [SecretMatch]) -> String {
        guard !matches.isEmpty else { return text }
        var out = ""; var cursor = text.startIndex
        for m in matches {
            out += text[cursor..<m.range.lowerBound]
            out += m.kind == .passwordInURL ? "[REDACTED]" : "[REDACTED \(m.kind.slug)]"
            cursor = m.range.upperBound
        }
        out += text[cursor...]
        return out
    }
}
```
`ContentKind`: `case secret` with `displayName` "Secrets". `ContentDetector.detect`: `if !SecretDetector.scan(text).isEmpty { kinds.insert(.secret) }`. `TransformCategory`: `static let privacy = "Privacy"`; `builtinOrder` gains `privacy` last. Check `JWTDecoder.split` is accessible (internal in the same module — yes).
- [ ] **Step 4:** filters green; full suite green (fix any test enumerating `ContentKind`/categories literally and say so).
- [ ] **Step 5: Commit** `feat(core): SecretDetector + SecretRedactor, ContentKind.secret, Privacy category`.

---

### Task 2: `RedactSecrets` transform + registry (Core, TDD)

**Files:** Create `Sources/PastefixCore/Native/RedactSecrets.swift`; Modify `Discovery/TransformerRegistry.swift`; Tests `Tests/PastefixCoreTests/RedactSecretsTests.swift` (new), `TransformerRegistryTests.swift` (extend: count +1, id list, categories).

- [ ] **Step 1: Tests**
```swift
import Testing
@testable import PastefixCore

@Suite struct RedactSecretsTests {
    @Test func metadataAndApply() async throws {
        let t = RedactSecrets()
        #expect(t.id == "builtin.redactsecrets" && t.name == "Redact Secrets" && t.category == TransformCategory.privacy && t.applicableKinds == [.secret] && !t.requiresRichInput)
        #expect(try await t.apply(TransformInput(text: "x AKIAIOSFODNN7EXAMPLE y")) == "x [REDACTED aws-access-key] y")
        #expect(try await t.apply(TransformInput(text: "nothing here")) == "nothing here")
    }
}
```
- [ ] **Step 2 → 3:** implement
```swift
public struct RedactSecrets: Transformer {
    public let id = "builtin.redactsecrets"
    public let name = "Redact Secrets"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let category: String? = TransformCategory.privacy
    public let applicableKinds: Set<ContentKind>? = [.secret]
    public init() {}
    public func apply(_ input: TransformInput) async throws -> String {
        SecretRedactor.redact(input.text, matches: SecretDetector.scan(input.text))
    }
}
```
Registry: `(110, "Redact Secrets", RedactSecrets())` after the 103 entry. Update the registry tests (count 26 → 27, ids, categories).
- [ ] **Step 4:** green. **Commit** `feat(core): Redact Secrets transform (order 110, Privacy)`.

---

### Task 3: Document matches and history flag (AppCore, TDD)

**Files:** Modify `Sources/PastefixAppCore/PasteDocument.swift`, `History/HistoryItem.swift`, `History/HistoryStore.swift`; Tests `PasteDocumentTests`, `HistoryStoreTests` (extend).

- [ ] Tests:
```swift
    // PasteDocumentTests
    @Test func secretMatchesPinnedAtDiscreteEvents() {
        var d = PasteDocument(origin: ClipboardSnapshot(plainText: "AKIAIOSFODNN7EXAMPLE", richRTFD: nil))
        #expect(d.secretMatches.map(\.kind) == [.awsAccessKey] && d.detectedKinds.contains(.secret))
        d.setWorking("plain now")                      // manual edit: not re-detected
        #expect(d.secretMatches.count == 1)
        d.pushState("plain now")                       // discrete event
        #expect(d.secretMatches.isEmpty && !d.detectedKinds.contains(.secret))
    }
    // HistoryStoreTests
    @Test func containsSecretFlagSetAtCaptureAndDecodesLegacyFalse() throws {
        try withDir { dir in
            let s = HistoryStore(directory: dir)
            let a = s.record(text("token=9f8e7d6c5b4a39281706f5e4d3c2b1a0"))!; let b = s.record(text("hello"))!
            let img = s.record(CaptureCandidate(imagePNG: png(1)))!
            #expect(a.containsSecret && !b.containsSecret && !img.containsSecret)
            let p = s.pinText("AKIAIOSFODNN7EXAMPLE", richRTFD: nil, title: nil)!
            #expect(p.containsSecret)
            s.flush()
            #expect(HistoryStore(directory: dir).items.first { $0.id == a.id }?.containsSecret == true)
            let legacy = #"[{"id":"00000000-0000-0000-0000-000000000002","capturedAt":"2026-09-01T00:00:00Z","plainText":"AKIAIOSFODNN7EXAMPLE","byteCount":20}]"#
            try Data(legacy.utf8).write(to: dir.appendingPathComponent("index.json"))
            #expect(HistoryStore(directory: dir).items[0].containsSecret == false)   // not recomputed at load
        }
    }
```
- [ ] Implement: `PasteDocument`: `public private(set) var secretMatches: [SecretMatch]` set in `init` and `redetect()` via `SecretDetector.scan(working)`. `HistoryItem`: `public var containsSecret: Bool = false` (memberwise default; decoder `decodeIfPresent ?? false`; add to `CodingKeys`). `HistoryStore.record`: for a new text item `item.containsSecret = !SecretDetector.scan(t).isEmpty` (text only); `pinText` promoting an existing item recomputes it from the item's text (`items[i].containsSecret = …`). Do not recompute at load (cheap enough, but keeps load pure; documented).
- [ ] green; **Commit** `feat(appcore): PasteDocument.secretMatches; HistoryItem.containsSecret set at capture`.

---

### Task 4: App — badge, selection, overlay glyph

**Files:** Modify `Pastefix/Pastefix/AppModel.swift`, `PanelView.swift`, `HistoryOverlayView.swift`.

- [ ] `AppModel`:
```swift
    @Published var editorSelection: TextSelection?       // import SwiftUI at top of AppModel.swift
    private var nextSecretIndex = 0
    var secretMatches: [SecretMatch] { document?.secretMatches ?? [] }
    /// Detected badge text; never lists "Secrets" (the orange badge owns that).
    var detectedSummary: String? { … filter { $0 != .secret } … }
    func selectNextSecret() {
        guard let doc = document else { return }
        let live = SecretDetector.scan(doc.working)          // never act on pinned ranges
        guard !live.isEmpty else { return }
        nextSecretIndex %= live.count
        editorSelection = TextSelection(range: live[nextSecretIndex].range)
        nextSecretIndex += 1
    }
```
  Reset `nextSecretIndex = 0` in `summon`/`load`.
- [ ] `PanelView`: `TextEditor(text: workingBinding, selection: $model.editorSelection)`; in the action bar before the Detected badge:
```swift
            if !model.secretMatches.isEmpty && !isPaletteOpen && !isHistoryOpen {
                let n = model.secretMatches.count
                Button { model.selectNextSecret(); editorFocused = true } label: {
                    Label("\(n) secret\(n == 1 ? "" : "s")", systemImage: "exclamationmark.shield")
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Looks like credentials: \(Set(model.secretMatches.map(\.kind.displayName)).sorted().joined(separator: ", ")). Click to select the next one; use Redact Secrets (⌘K) to mask them.")
                .accessibilityLabel("\(n) possible secrets; click to select the next one")
            }
```
- [ ] `HistoryOverlayView` row: leading `Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)` when `item.containsSecret` (before the pin glyph if both), `.help("Looks like it contains a credential")`.
- [ ] Build → BUILD SUCCEEDED, no new warnings (if `TextSelection`/`selection:` is unavailable at the target, report BLOCKED with the exact diagnostic — the fallback is a badge without selection). `swift test` unchanged. **Commit** `feat(app): secrets badge selects matches; Detected omits Secrets; overlay shield glyph`.

---

### Task 5: Docs

- [x] README "Secrets" subsection; AGENTS: layout, Patterns ("every detector regex bounded + a timing test"), Invariant 8 orders gain `110`, status row Plan 11 (🟡); banner. **Commit** `docs: secret detector — README (incl. macOS 15 requirement), AGENTS, spec amendments, release notes wording`.

---

### Task 6: GUI pass (controller, ask first) and finish

- [ ] Fake `AKIAIOSFODNN7EXAMPLE` + `api_key=9f8e…` buffer → badge "2 secrets", Detected badge unaffected → click selects (verify via ⌘C? no — screenshot) → ⌘K "redact" ↵ → tokens, badge gone → ⌘⇧V row shows the shield. Save/restore the clipboard.
- [ ] Final review, one fix wave, AGENTS "bitten us", PR closing #13, `git checkout main`.

## Self-review
- Coverage: detector/redactor/kind/category (T1); transform + registry (T2); document + history (T3); badge/selection/glyph (T4); docs (T5); pass (T6).
- Names: `SecretDetector.scan/maxBytes/entropy`, `SecretRedactor.redact(_:matches:)`, `SecretKind.displayName/slug`, `SecretMatch.kind/range`, `PasteDocument.secretMatches`, `HistoryItem.containsSecret`, `AppModel.secretMatches/selectNextSecret/editorSelection`.
