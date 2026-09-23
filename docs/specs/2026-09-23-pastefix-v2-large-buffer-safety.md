---
type: spec
status: draft
id: 2026-09-23-pastefix-v2-large-buffer-safety
title: Pastefix v2 — Large-Buffer Safety (Plan 13)
description: Content detection and the secret scan run off the main actor and land late under a revision/generation guard; the URL detector gets its own 256 KB cap; every transform declares an input cap and a timeout, the coordinator enforces both through a shared deadline helper, and dismissing the session cancels the in-flight apply.
tags: [pastefix, macos, swift, performance, concurrency, transforms, detection]
timestamp: 2026-09-23T14:00:00Z
issues: [28, 29]
---

# Pastefix v2 — Large-Buffer Safety (Plan 13)

## Amendments (post-implementation)

The sections below are updated in place to match what shipped; this list is the summary of what
changed and why, for anyone comparing against an earlier read of this spec.

1. **Defaults live in `TransformLimits`, not `Transformer`.** `Transformer.maxInputBytes`/`timeout`
   default to `TransformLimits.defaultMaxInputBytes` (1 MB) / `TransformLimits.defaultTimeout` (3 s)
   — a standalone enum in `Transformer.swift`, not static members of the protocol's default
   extension.
2. **The problem statement overstated where native transforms blocked.** `TransformCoordinator.apply`
   is a nonisolated `async` function in the package, so a synchronous native body already ran off
   the main actor before this plan; it was unbounded and uncancellable, not main-actor-blocking.
   Detection was the actual main-actor cost: `PasteDocument.init`/`pushState`/`undo`/`redo` ran
   `SecretDetector.scan` + `ContentDetector.detect` as part of a struct's synchronous init/mutation
   on `AppModel`, a `@MainActor` class.
3. **`Deadline.run` checks cancellation before starting.** It begins with `try
   Task.checkCancellation()`, so an already-cancelled caller never spawns the body task at all.
4. **The scheduler's single slot is soft across `cancelAll()`.** `cancelAll()` lets go of a running
   scan rather than waiting for it: the scan keeps running to completion in the background,
   cancelled and undelivered, and a `request` called immediately afterward may briefly overlap it.
   The overlap is bounded by the same caps as any other scan and by `URLFinder` observing
   cancellation.
5. **`URLFinder.find` may return a partial list to a cancelled caller.** Every caller that is
   cancelled discards its result regardless, so the partial list is never surfaced.

Closes #28 (detection cost on the main actor) and #29 (native transforms have no input bound or
cancellation).

## Problem

- `PasteDocument.init`, `pushState`, `undo` and `redo` run `SecretDetector.scan` and
  `ContentDetector.detect` synchronously. Every caller is `AppModel`, a `@MainActor` class, so
  summon, every apply, undo, redo, refresh and history load block the run loop for the whole scan.
  `URLFinder` (NSDataDetector) alone costs ~1.75 s at the 1 MB detection cap; the panel does not
  appear until it finishes.
- `URLFinder.find(in:)` has no cap of its own and is called over the whole buffer from three
  places: detection, `URLCleaner` and `MarkdownLink`.
- Native transforms have no input bound. `MarkdownToRich` runs the same `MarkdownHTML.render`
  pipeline that `MarkdownPreview` capped at 16 KB / 200 list items in Plan 10, with no cap.
  Only `RegexPresetTransformer` and `RedactSecrets` bound themselves.
- Native transforms have no input bound or timeout, and no cancellation reaches a running one.
  `TransformCoordinator.apply` is a nonisolated `async` function in the package, so a synchronous
  native body does not itself block the main actor; the defect is that it is unbounded and
  uncancellable — a pathological input just runs to completion off-main, and Cancel/Save/re-summon
  only discard the result through the `sessionGeneration` guard while the work keeps running.

## Goals

1. The panel appears as soon as the clipboard is read, whatever the buffer size. Kinds and secret
   badges fill in when the scan completes; a stale scan never lands on a newer buffer.
2. No native transform can hold the panel disabled for longer than its declared timeout, and no
   transform runs over an input it has not declared it can afford.
3. Dismissing or replacing the session cancels the in-flight apply and detection.
4. One deadline mechanism, shared, instead of per-call hand-rolled races.

## Non-goals (recorded, not addressed)

- `ClipboardBridge.snapshot()` reads the pasteboard string uncapped; string materialisation of a
  pathological clipboard is not bounded here.
- `HistoryStore.record` still scans for secrets synchronously on capture, under the existing
  256 KB `SecretDetector` cap.
- `richRTFD` bytes do not count toward a transform's input cap; rich imports run off-main under
  the timeout, and a started AppKit import runs to completion.
- `AppModel.selectNextSecret` keeps its live per-click scan (bounded by `isScannable`).
- No cancel button for an in-flight apply: the timeout bounds it.

## Design

### 1. Detection state on the document

`PasteDocument` stops scanning. It carries:

```swift
public enum DetectionState: Sendable, Equatable { case pending, complete(DetectionResult) }
public struct DetectionResult: Sendable, Equatable {
    public let kinds: Set<ContentKind>
    public let secretMatches: [SecretMatch]
    public let secretScanSkipped: Bool
    /// Pure and synchronous; the thing the scheduler runs off the main actor.
    public static func compute(_ text: String) -> DetectionResult
}
```

- `public private(set) var detection: DetectionState` and `public private(set) var
  detectionRevision: Int`. `init` sets `.pending` and revision 0. `pushState`, `undo` and `redo`
  set `.pending` and increment the revision, on exactly the events that used to call `redetect()`
  (`setWorking` still does not).
- `detectedKinds`, `secretMatches`, `secretScanSkipped` become computed: empty / `[]` / `false`
  while pending. New `public var isDetecting: Bool`.
- `public mutating func applyDetection(_ result: DetectionResult, revision: Int) -> Bool` installs
  the result only when `revision == detectionRevision` and the state is still pending; returns
  whether it applied. The caller (`AppModel`) additionally guards on `sessionGeneration`.
- `DetectionResult.compute` is the one place `SecretDetector.scan` + `ContentDetector.detect(_:secrets:)`
  are paired, preserving the single-scan-two-consumers rule.

### 2. `DetectionScheduler` (AppCore, `@MainActor final class`)

```swift
public struct DetectionRequest: Sendable { public let text: String; public let revision: Int; public let generation: Int }
public init(compute: @escaping @Sendable (String) -> DetectionResult = DetectionResult.compute,
            deliver: @escaping @MainActor (DetectionRequest, DetectionResult) -> Void)
public func request(_ req: DetectionRequest)
public func cancelAll()
```

- One scan runs at a time on `Task.detached(priority: .userInitiated)`. A request arriving while
  one runs becomes the single **waiting** request, replacing any earlier waiting one, and the
  running detached task is cancelled (`URLFinder` observes cancellation; the other rules are
  fast). Same single-slot shape as `TIFFConversionSlot`, for the same reason: serialising
  without a slot would let rapid undo/redo stack 1 MB scans.
- When a scan finishes, its result is delivered only if no waiting request has displaced it;
  otherwise it is discarded and the waiting request starts. `cancelAll()` drops the waiting
  request and lets go of the running one rather than waiting for it: that scan keeps running to
  completion in the background, cancelled and undelivered, and an immediate `request` right after
  `cancelAll()` may briefly overlap it — bounded by the same caps as any other scan and by
  `URLFinder` observing cancellation, so nothing accumulates.
- `deliver` runs on the main actor with the originating request, so the receiver can compare
  generation and revision.

### 3. `AppModel` wiring (app target)

- Owns one `DetectionScheduler`. Every site that assigns a new `document` or changes its
  revision (`summon`, `load`, `refresh`, the apply completion, `undo`, `redo`) calls
  `requestDetection()`, which submits `(working, detectionRevision, sessionGeneration)`.
- `deliver`: `guard sessionGeneration == req.generation, var doc = document else { return }`;
  `if doc.applyDetection(result, revision: req.revision) { document = doc }`.
- `endSession()` and every `sessionGeneration &+= 1` site call `detection.cancelAll()` and
  `applyTask?.cancel()`.
- `var isDetecting: Bool { document?.isDetecting ?? false }` is exposed for the Zipline upload
  gate (#14) to await before deciding a buffer is secret-free.
- UI: while pending, the Detected label and both secret badges are simply absent (the existing
  `nil`/empty paths). No "Detecting…" copy: small buffers complete in milliseconds and the badge
  would flicker on every summon.

### 4. `URLFinder` bound

- `static let maxBytes = 262_144` (matches `SecretDetector.maxBytes`). `find(in:)` returns `[]`
  when `text.utf8.count > maxBytes`.
- Matching switches to `enumerateMatches(in:options: [.reportProgress], range:)` and stops when
  `Task.isCancelled`. A cancelled caller may receive a partial list; every caller that is
  cancelled discards its result, so partial output is never used.
- Consequence, documented in `ContentDetector`: the `.url` kind is not reported for buffers over
  256 KB even though `ContentDetector.maxBytes` stays 1 MB; the JSON, colour, base64/JWT,
  percent-encoding, entity and Markdown rules still run up to 1 MB.

### 5. `Transformer` caps and timeouts

```swift
public enum TransformLimits {
    public static let defaultMaxInputBytes = 1_048_576
    public static let defaultTimeout: TimeInterval = 3
}

public protocol Transformer {
    // existing requirements…
    /// Largest `TransformInput.text` (UTF-8 bytes) this transform accepts. Enforced by the coordinator.
    var maxInputBytes: Int { get }        // default TransformLimits.defaultMaxInputBytes = 1_048_576
    /// Wall-clock budget for `apply`. Enforced by the coordinator via `Deadline.run`.
    var timeout: TimeInterval { get }     // default TransformLimits.defaultTimeout = 3
}
```

| Transformer | maxInputBytes | timeout |
|---|---|---|
| default (all natives not listed, Shell, JS) | 1 MB | 3 s (Shell/JS: their existing `timeout`, made non-private) |
| `MarkdownToRich` | 64 KB | 3 s |
| `URLCleaner`, `MarkdownLink` | `URLFinder.maxBytes` (256 KB) | URLCleaner 3 s; MarkdownLink `fetchTimeout + 2` (6 s by default, the one batch of fetches plus margin) |
| `RedactSecrets` | `SecretDetector.maxBytes` | 3 s |
| `RegexPresetTransformer` | `Self.maxBytes` (256 KB) | its existing `timeout` (3 s) |

Internal checks already in `RedactSecrets` and `RegexPresetTransformer.checkInputSize` stay: the
Settings preview calls presets without the coordinator.

### 6. `Deadline.run` (Core)

```swift
public enum Deadline {
    /// Begins with `try Task.checkCancellation()`, so an already-cancelled caller never spawns
    /// `body`. Otherwise runs `body` on a detached task and returns its value. Throws
    /// `TransformError.timeout` when `seconds` elapse first, and `CancellationError` when the
    /// caller is cancelled first. In both abandonment cases the body task is cancelled and its
    /// eventual result discarded; a body that ignores cancellation runs to completion in the
    /// background but never blocks the caller.
    public static func run<T: Sendable>(seconds: TimeInterval, priority: TaskPriority = .userInitiated,
                                        _ body: @escaping @Sendable () async throws -> T) async throws -> T
}
```

Implemented with `withTaskCancellationHandler` around a `withCheckedThrowingContinuation` whose
continuation is resumed exactly once (lock-guarded) by whichever finishes first: the body task,
a sleeper task, or the cancellation handler. This is the JSRunner race made honest: it states
that it abandons rather than stops, and it always cancels the body so cooperative bodies stop.

`RegexPresetTransformer.apply` adopts `Deadline.run` in place of its task-group race; its
in-loop check becomes `ContinuousClock.now > deadline || Task.isCancelled`. `MarkdownLink`'s
non-throwing fetch race and `JSRunner`/`ShellRunner` are left alone.

### 7. `TransformCoordinator.apply`

```swift
public static func apply(_ transformer: any Transformer, to document: PasteDocument) async -> (PasteDocument, TransformOutcome)
```

1. If `input.text.utf8.count > transformer.maxInputBytes`, return
   `.failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of text.")`
   without calling `apply`. `ByteLimit.describe` renders binary units: 65_536 → "64 KB",
   262_144 → "256 KB", 1_048_576 → "1 MB".
2. Otherwise `try await Deadline.run(seconds: transformer.timeout) { try await transformer.apply(input) }`.
   `TransformError.timeout` maps to the existing "The transform timed out."; `CancellationError`
   maps to `.failed("The transform was cancelled.")` (always dropped by the generation guard in
   practice).
3. `pushState` and the rest are unchanged; `pushState` now only marks detection pending, and the
   model requests a scan after installing the document.

`AppModel.apply` keeps the task handle in `applyTask`; cancellation from `endSession`/summon
propagates through `Deadline.run` to the body.

### 8. Cooperative cancellation points

`URLFinder` (via `.reportProgress`) and `RegexPresetTransformer.replace` (existing block) check
`Task.isCancelled`. Other native bodies are linear over inputs now capped at 1 MB or are
Foundation calls that cannot be interrupted; the caps are their bound. No checks are added to
them.

## Testing

Core:
- `URLFinderTests`: over-cap input returns `[]`; at-cap input still finds URLs; a cancelled task
  stops enumeration early (observable via a large URL-dense input and elapsed time).
- `DeadlineTests`: fast body returns its value; stubborn body (busy loop ignoring cancellation
  for 2 s) with a 0.2 s deadline throws `.timeout` within 0.6 s; cooperative body stops when
  the deadline fires (flag observed); cancelling the caller throws `CancellationError` and
  cancels the body; a body that throws propagates its error.
- `TransformerCapsTests`: table asserting `maxInputBytes`/`timeout` for every built-in
  transformer via the registry, plus defaults for a stub conformer.
- `RegexPresetTests`: existing deadline tests still pass under `Deadline.run`.

AppCore:
- `PasteDocumentTests`: init is pending with revision 0; push/undo/redo bump the revision and
  reset to pending; `applyDetection` with a stale revision returns false and leaves state
  pending; computed accessors are empty while pending; `DetectionResult.compute` equals the
  pre-Plan-13 behaviour for URL, JSON and secret fixtures.
- `DetectionSchedulerTests` (injected slow `compute`): one scan at a time; a request during a
  run replaces the waiting one; the displaced run's result is not delivered; `cancelAll`
  delivers nothing; delivery carries the originating request.
- `TransformCoordinatorTests`: over-cap returns `.failed` with the formatted limit and never
  calls `apply`; a transformer whose `apply` sleeps past its `timeout` returns
  "The transform timed out."; a cancelled outer task returns `.failed("The transform was cancelled.")`;
  the returned document is pending with a bumped revision.

App (GUI pass, with permission at the time, clipboard saved and restored):
- Summon with a 1 MB URL-dense buffer: panel visible immediately; "Detected: URL" absent
  (over the URL cap) but JSON/Markdown kinds appear for a 900 KB JSON buffer within a second.
- Markdown → Rich Text on a 2 MB buffer: red banner "Markdown → Rich Text is limited to 64 KB of text."
- Clean URL Tracking on a 300 KB buffer: banner with "256 KB".
- Esc during a slow apply (a shell script that sleeps): panel closes at once; log shows the
  cancellation; the next summon is not `isApplying`.

## Documentation

- AGENTS: status row "13 — Large-buffer safety"; a new Pattern ("Session text is scanned off
  the main actor; results land by revision and generation. Never call `SecretDetector`/
  `ContentDetector` on the main actor for session text."), the `maxInputBytes`/`timeout`
  contract for new transformers, and `Deadline.run` as the only sanctioned deadline race; a
  "bitten us" entry for the inline-await-on-main-actor trap and the JSRunner-style false
  cancellation.
- Foundation and content-transforms specs: amendment notes pointing here.
