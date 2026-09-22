---
type: spec
status: approved
id: 2026-09-21-pastefix-v2-secret-detector
title: Pastefix v2 — Secret Detector & Redaction (Plan 11)
description: Bounded-regex detection of credentials in the working buffer (AWS, GitHub, OpenAI, Slack, Stripe, Google keys, private-key blocks, JWTs, passwords in URLs, high-entropy key=value assignments); an orange warning badge that selects matches in the editor; a "Redact Secrets" transform; a persisted flag on history items shown as a glyph in the overlay. Save is unchanged; the scan is the hook for #14's upload confirmation.
tags: [pastefix, macos, swift, security, secrets, detection]
timestamp: 2026-09-21T12:00:00Z
---

# Pastefix v2 — Secret Detector & Redaction (Plan 11)

Source: [issue #13](https://github.com/bnaylor/pastefix/issues/13). Scope decided with the
user: secrets only (no PII), badge only (⌘S unchanged), history records and flags (no
refusal). Builds on Plan 3 (kinds/detection), Plan 6 (history items), Plan 8's bounded-regex
lesson.

## Scope

**In scope:**

- `SecretDetector.scan(_:) -> [SecretMatch]` in `PastefixCore`; `SecretKind` with display
  names and redaction tokens; `ContentKind.secret` inserted by `ContentDetector` when the
  scan is non-empty.
- `RedactSecrets` transform (`builtin.redactsecrets`, order 110, category **Privacy**,
  `applicableKinds: [.secret]`): replaces each match with `[REDACTED <kind-slug>]`;
  password-in-URL replaces only the password; idempotent.
- App: `AppModel.secretMatches` (recomputed at the same discrete events as `detectedKinds`,
  re-scanned live on badge click); orange warning badge "N secret(s)" with kinds in the
  tooltip; click selects the next match in the editor (`TextEditor(text:selection:)`).
  The Detected badge omits `.secret`.
- History: `HistoryItem.containsSecret: Bool` set at `record`/`pinText` time; overlay rows
  show a shield glyph; legacy indexes decode as `false`.
- README, AGENTS (layout; Patterns: every detector regex bounded, per-line cap), spec.

**Out of scope:** PII (emails, phones, cards); refusing captures; a Save confirmation;
Settings toggles; per-kind enable/disable; entropy tuning UI; the upload prompt itself
(#14 will call `SecretDetector.scan`).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Patterns (all anchored/bounded) | AWS access key `\b(AKIA|ASIA)[0-9A-Z]{16}\b`; AWS secret: `(?i)aws[_-]?secret[_-]?(access[_-]?)?key\W{0,5}([A-Za-z0-9/+=]{40})`; GitHub `\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b` and `\bgithub_pat_[A-Za-z0-9_]{22,255}\b`; OpenAI `\bsk-(proj-)?[A-Za-z0-9_-]{20,200}\b`; Slack `\bxox[abprs]-[A-Za-z0-9-]{10,200}\b`; Stripe `\b(sk|rk)_live_[A-Za-z0-9]{16,200}\b`; Google `\bAIza[0-9A-Za-z_-]{35}\b`; private key block `-----BEGIN [A-Z ]{0,20}PRIVATE KEY-----[\s\S]{0,8192}?-----END [A-Z ]{0,20}PRIVATE KEY-----`; JWT via existing `JWTDecoder.split` on whitespace-delimited tokens; password in URL `\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@]{1,64}:([^\s/@]{1,128})@`; generic assignment `(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?token|client[_-]?secret)\b\s*[:=]\s*["']?([A-Za-z0-9_\-+/=.]{16,256})["']?` with Shannon entropy of the value ≥ 3.5 bits/char | The well-known prefixes are near-zero false positive; the generic rule needs a key name AND entropy so `password=changeme` and `token = null` don't fire. All quantifiers bounded. |
| Scan limits | 1 MB guard (existing), per-line cap 4 096 chars for the multi-char patterns, private-key block capped at 8 KB | Plan 8's quadratic-backtracking lesson. |
| Redaction tokens | `[REDACTED aws-access-key]`, `[REDACTED private-key]`, …; URL password → `user:[REDACTED]@host`; JWT → `[REDACTED jwt]` | Typed tokens tell the reader what was there; stable, greppable, and the detector doesn't match its own output (idempotent). |
| Where matches live | `PasteDocument.secretMatches` computed alongside `detectedKinds` at discrete events; badge click re-scans `working` live | Same pinning rule as detection; ranges can't be stale when acted on. |
| Badge | Orange capsule `exclamationmark.shield` "N secrets" beside Detected; tooltip lists kinds; click → select next match (cycles) | Reuses the action-bar badge idiom; selection makes "where?" one click. |
| Category | New `TransformCategory.privacy` "Privacy", last in `builtinOrder` | Redaction is a privacy action, not Data. |
| History | Flag at capture, glyph in the overlay; no refusal | User's call; visibility without data loss. |
| Save | Unchanged | User's call; the risky step is upload/share (#14). |

## Architecture

### PastefixCore

```swift
public enum SecretKind: String, CaseIterable, Sendable {
    case awsAccessKey, awsSecretKey, githubToken, openAIKey, slackToken, stripeKey, googleAPIKey,
         privateKey, jwt, passwordInURL, genericAssignment
    public var displayName: String      // "AWS access key", "GitHub token", … "credential assignment"
    public var slug: String             // "aws-access-key", …, "credential"
}
public struct SecretMatch: Sendable, Equatable {
    public let kind: SecretKind
    public let range: Range<String.Index>          // whole token; for passwordInURL the PASSWORD only
}
public enum SecretDetector {
    public static let maxBytes = 1_048_576
    public static func scan(_ text: String) -> [SecretMatch]   // sorted by range, non-overlapping (first wins)
    static func entropy(_ s: String) -> Double
}
public enum SecretRedactor {
    public static func redact(_ text: String, matches: [SecretMatch]) -> String
}
public struct RedactSecrets: Transformer { /* builtin.redactsecrets, "Redact Secrets", order 110, category privacy, applicableKinds [.secret] */ }
// ContentKind.secret (displayName "Secrets"); ContentDetector inserts it when scan is non-empty.
// TransformCategory.privacy = "Privacy"; builtinOrder += [privacy].
```

### PastefixAppCore

- `PasteDocument.secretMatches: [SecretMatch]` recomputed in `redetect()` and `init`
  (same events as `detectedKinds`).
- `HistoryItem.containsSecret: Bool` (tolerant decode → false); `HistoryStore.record` and
  `pinText` set it from `SecretDetector.scan(text).isEmpty == false` (text only; images no).
- `PaletteOrdering`/`TransformSearch` need no change (`applicableKinds` already works).

### Pastefix app

- `AppModel`: `detectedSummary` excludes `.secret`; `var secretMatches: [SecretMatch]`
  (from the document); `func selectNextSecret()` re-scans `working`, advances an index,
  and publishes `editorSelection: TextSelection?` (macOS 15 API; app target is 26.3).
- `PanelView`: `TextEditor(text: workingBinding, selection: $editorSelection)` bound to the
  model's published selection; badge in the action bar:
  `Button { model.selectNextSecret() } label: { Label("\(n) secret\(n == 1 ? "" : "s")", systemImage: "exclamationmark.shield") }`
  orange tint, `.help("Looks like credentials: <kinds>. Click to select the next one. Use Redact Secrets (⌘K) to mask them.")`,
  visible when `n > 0` and no overlay is open.
- `HistoryOverlayView` row: leading `shield.lefthalf.filled` (orange) when `item.containsSecret`.

## Data flow

Copy a `.env` → ⌘⇧C → scan finds `AWS_SECRET_ACCESS_KEY=…` and `sk-…` → Detected badge shows
nothing extra, the orange badge says "2 secrets" → click → the first value is selected in
the editor → ⌘K "redact" ↵ → both replaced with tokens → badge disappears → ⌘S. In ⌘⇧V, the
original capture row carries the shield glyph.

## Error handling

- Over 1 MB → no scan (consistent with detection).
- Regex failure at init is a programmer error (`try!`), covered by tests.
- Redaction of overlapping matches: matches are non-overlapping by construction (first
  match wins per position).

## Testing

`Tests/PastefixCoreTests/SecretDetectorTests`: one positive and one near-miss negative per
kind (e.g. `AKIA` + 15 chars; `ghp_` too short; `sk-` in prose "task-list"; `password=changeme`
low entropy; `token = 0123456789abcdef0123` entropy high enough? — assert the intended
outcome); URL password range covers only the password; JWT via three base64url segments;
private key block with a 20 KB body → only first 8 KB considered (still matched or not —
pin the behaviour); 64 KB line of `sk-` fragments completes < 100 ms; 1 MB+ → empty.
`SecretRedactorTests`: tokens per kind; URL keeps user/host; idempotent (`redact(redact(x)) == redact(x)`); mixed text preserves surrounding characters.
`RedactSecretsTests`: transformer metadata; `applicableKinds`; registry order 110 in Privacy.
`ContentDetectorTests`: `.secret` inserted; coexists with `.url`.
AppCore: `PasteDocument.secretMatches` pinned at push/undo; `HistoryStore` flag set for a
secret text, false for plain, false for images; legacy decode.

GUI pass (ask first): fake `AKIAIOSFODNN7EXAMPLE` + `sk-…` buffer → badge "2 secrets" →
click selects → Redact Secrets → tokens → badge gone; overlay row glyph; Detected badge
unaffected. Restore clipboard.

## Documentation

- README: "Secrets" subsection (what's detected, the badge, Redact Secrets, the history glyph,
  that nothing is blocked or uploaded, and that Save is unchanged).
- AGENTS.md: layout (`Detection/SecretDetector.swift`, `Native/RedactSecrets.swift`);
  Patterns: "Every detector regex is bounded and line-capped; add a timing test with any new
  pattern"; Invariant 8 orders gain `110`; status row.

## Project layout delta

```
Sources/PastefixCore/Detection/SecretDetector.swift     # kinds, scan, entropy, redactor
Sources/PastefixCore/Detection/ContentKind.swift        # .secret
Sources/PastefixCore/Detection/ContentDetector.swift    # inserts .secret
Sources/PastefixCore/Native/RedactSecrets.swift
Sources/PastefixCore/Transformer.swift                  # TransformCategory.privacy
Sources/PastefixCore/Discovery/TransformerRegistry.swift # order 110
Sources/PastefixAppCore/PasteDocument.swift             # secretMatches
Sources/PastefixAppCore/History/HistoryItem.swift       # containsSecret
Sources/PastefixAppCore/History/HistoryStore.swift      # set flag at record/pinText
Pastefix/Pastefix/AppModel.swift                        # secretMatches, selectNextSecret, editorSelection
Pastefix/Pastefix/PanelView.swift                       # badge, selection binding
Pastefix/Pastefix/HistoryOverlayView.swift              # shield glyph
```
