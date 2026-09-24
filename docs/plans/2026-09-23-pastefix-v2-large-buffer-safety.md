# Pastefix v2 Large-Buffer Safety (Plan 14) — Implementation Plan

> ## ✅ STATUS: COMPLETE — merged to main via PR #53 (`7bd250c`, 2026-09-24)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; concurrency (Tasks 1, 4, 5, 6) → `swift-concurrency-pro`. **TDD is required** for every package task. **One implementer at a time on the branch.** The GUI pass is the controller's, with the user's permission.

**Post-review deltas:** the spec's Amendments are authoritative where this plan's task text differs (rich transforms capped on RTFD bytes; script `timeout = runnerTimeout + 1`; two over-cap messages, text and rich; `refresh` carries `detectionRevision`; hard scheduler slot under a scan deadline; palette ranks against a kinds snapshot).

**Goal:** Detection and the secret scan run off the main actor and land by revision/generation; every transform declares an input cap and a timeout that the coordinator enforces through one shared deadline helper; dismissing the session cancels in-flight work.

**Architecture:** `PastefixCore` gains `Deadline.run` (abandon-at-deadline race that always cancels its body), `ByteLimit.describe`, `TransformLimits` defaults, two new `Transformer` requirements with defaults, a 256 KB cap plus cancellation check in `URLFinder`, and per-transformer overrides. `PastefixAppCore` gains `DetectionResult`/`DetectionState` on `PasteDocument` (no scanning in the struct any more), a `DetectionScheduler` single-slot lane, and a `TransformCoordinator` that checks the cap and runs `apply` under `Deadline.run`. The app wires the scheduler and cancels the apply task wherever the session changes.

**Tech Stack:** Swift 6 SwiftPM (macOS 14+), structured concurrency (`withTaskCancellationHandler`, `withCheckedThrowingContinuation`, detached tasks), `NSDataDetector.enumerateMatches(options: [.reportProgress])`, Swift Testing.

**Spec:** `docs/specs/2026-09-23-pastefix-v2-large-buffer-safety.md` — read it first.

## Global Constraints

- **Caps/timeouts:** `TransformLimits.defaultMaxInputBytes = 1_048_576`, `TransformLimits.defaultTimeout: TimeInterval = 3`. Overrides: `MarkdownToRich.maxInputBytes = 65_536`; `URLCleaner`/`MarkdownLink.maxInputBytes = URLFinder.maxBytes` (`262_144`); `MarkdownLink.timeout = fetchTimeout + 2` (6 s default); `RedactSecrets.maxInputBytes = SecretDetector.maxBytes`; `RegexPresetTransformer.maxInputBytes = Self.maxBytes`, `timeout = Self.timeout`; `ShellTransformer`/`JSTransformer` timeout is `runnerTimeout + 1` (post-review — see spec Amendment 7), a margin over the runner's own watchdog rather than the runner's raw configured value.
- **Messages:** over cap is two messages, not one, per spec Amendment 6 — a rich transform (`requiresRichInput`) is measured on `richRTFD` bytes and refuses with `"\(name) is limited to \(ByteLimit.describe(maxInputBytes)) of rich text."`; every other transform is measured on `text.utf8.count` and refuses with `"…of text."`. `ByteLimit.describe`: `65_536 → "64 KB"`, `262_144 → "256 KB"`, `1_048_576 → "1 MB"`, `4_194_304 → "4 MB"`, otherwise `"\(n) bytes"`. Timeout → existing `"The transform timed out."`. Caller cancelled → `"The transform was cancelled."`.
- **Deadline.run contract:** returns the body's value; throws `TransformError.timeout` when `seconds` elapse first; throws `CancellationError` when the caller is cancelled first; in both cases the body task is cancelled and its eventual result discarded; a body that ignores cancellation never blocks the caller. Body runs on `Task.detached(priority:)`, default `.userInitiated`.
- **Detection state:** `PasteDocument.init` → `.pending`, `detectionRevision == 0`; `pushState` (including equal text), `undo`, `redo` → `.pending` and `detectionRevision += 1`; `setWorking` touches neither. `refresh` carries the previous revision forward: `.pending` at `detectionRevision + 1` from the pre-refresh value, not a reset to 0 (post-review — see spec Amendment 8), so a scan result computed for the pre-refresh document at some revision can never be mistaken for one computed post-refresh at the same revision. `applyDetection(_:revision:)` applies only when `revision == detectionRevision && detection == .pending`, returns `Bool`. While pending: `detectedKinds == []`, `secretMatches == []`, `secretScanSkipped == false`, `isDetecting == true`.
- **Scheduler:** at most one scan running (detached, `.userInitiated`); a request during a run becomes the single waiting request (replacing any earlier waiting one) and cancels the running task; a finished scan is delivered only if it was not cancelled and nothing is waiting; `cancelAll()` delivers nothing afterwards. `deliver` runs on the main actor with the originating request.
- **URLFinder:** `maxBytes = 262_144`; over cap returns `[]`; enumeration stops when `Task.isCancelled`.
- **Branch:** `feat/large-buffer-safety` (already exists, spec committed). Conventional commits + `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #28 and #29. `main` is protected.

---

### Task 0: Baseline

- [ ] `git checkout feat/large-buffer-safety && git pull --ff-only && swift test 2>&1 | tail -1` → `438 tests in 51 suites passed`.

---

### Task 1: `Deadline.run`, `ByteLimit`, `TransformLimits` (Core, TDD)

**Files:** Create `Sources/PastefixCore/Deadline.swift`, `Sources/PastefixCore/ByteLimit.swift`; Modify `Sources/PastefixCore/Transformer.swift` (add `TransformLimits`); Tests create `Tests/PastefixCoreTests/DeadlineTests.swift`, `Tests/PastefixCoreTests/ByteLimitTests.swift`.

**Interfaces produced:** `Deadline.run(seconds:priority:_:)`, `ByteLimit.describe(_:)`, `TransformLimits.defaultMaxInputBytes`, `TransformLimits.defaultTimeout`.

- [ ] **Step 1: Failing tests**

```swift
// Tests/PastefixCoreTests/DeadlineTests.swift
import Testing
import Foundation
@testable import PastefixCore

/// Lock-guarded flag a detached body can set and the test can poll.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

private func waitFor(_ flag: Flag, upTo seconds: Double = 2) async {
    let end = ContinuousClock.now + .seconds(seconds)
    while !flag.value, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite struct DeadlineTests {
    @Test func fastBodyReturnsItsValue() async throws {
        let v = try await Deadline.run(seconds: 5) { 42 }
        #expect(v == 42)
    }

    @Test func bodyErrorPropagates() async {
        await #expect(throws: TransformError.invalidInput("bad")) {
            try await Deadline.run(seconds: 5) { () -> Int in throw TransformError.invalidInput("bad") }
        }
    }

    @Test func stubbornBodyDoesNotBlockTheCaller() async {
        // Thread.sleep is not a cancellation point: this body cannot be stopped, only abandoned.
        let start = ContinuousClock.now
        await #expect(throws: TransformError.timeout) {
            try await Deadline.run(seconds: 0.2) { () -> Int in Thread.sleep(forTimeInterval: 1.0); return 1 }
        }
        #expect(ContinuousClock.now - start < .seconds(0.8))
    }

    @Test func deadlineCancelsACooperativeBody() async {
        let stopped = Flag()
        await #expect(throws: TransformError.timeout) {
            try await Deadline.run(seconds: 0.1) { () -> Int in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                stopped.raise()
                return 0
            }
        }
        await waitFor(stopped)
        #expect(stopped.value)
    }

    @Test func callerCancellationCancelsTheBody() async {
        let stopped = Flag()
        let outer = Task {
            try await Deadline.run(seconds: 10) { () -> Int in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                stopped.raise()
                return 0
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        outer.cancel()
        await #expect(throws: CancellationError.self) { try await outer.value }
        await waitFor(stopped)
        #expect(stopped.value)
    }

    @Test func alreadyCancelledCallerThrowsWithoutRunningLong() async {
        let outer = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Deadline.run(seconds: 10) { () -> Int in Thread.sleep(forTimeInterval: 1.0); return 1 }
        }
        let start = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await outer.value }
        #expect(ContinuousClock.now - start < .seconds(0.8))
    }
}
```

```swift
// Tests/PastefixCoreTests/ByteLimitTests.swift
import Testing
@testable import PastefixCore

@Suite struct ByteLimitTests {
    @Test func binaryUnits() {
        #expect(ByteLimit.describe(65_536) == "64 KB")
        #expect(ByteLimit.describe(262_144) == "256 KB")
        #expect(ByteLimit.describe(1_048_576) == "1 MB")
        #expect(ByteLimit.describe(2_097_152) == "2 MB")
        #expect(ByteLimit.describe(1_000) == "1000 bytes")
    }
    @Test func defaults() {
        #expect(TransformLimits.defaultMaxInputBytes == 1_048_576)
        #expect(TransformLimits.defaultTimeout == 3)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter "DeadlineTests|ByteLimitTests"` → compile failure (`Deadline` undefined).

- [ ] **Step 3: Implement**

```swift
// Sources/PastefixCore/ByteLimit.swift
import Foundation

/// Renders a byte cap the way the UI states it: binary units, whole numbers only.
public enum ByteLimit {
    public static func describe(_ bytes: Int) -> String {
        if bytes >= 1_048_576, bytes % 1_048_576 == 0 { return "\(bytes / 1_048_576) MB" }
        if bytes >= 1024, bytes % 1024 == 0 { return "\(bytes / 1024) KB" }
        return "\(bytes) bytes"
    }
}
```

```swift
// Sources/PastefixCore/Transformer.swift — add near TransformError
/// Defaults every transform gets unless it declares otherwise (see `Transformer.maxInputBytes`
/// and `Transformer.timeout`, added in Task 2).
public enum TransformLimits {
    public static let defaultMaxInputBytes = 1_048_576
    public static let defaultTimeout: TimeInterval = 3
}
```

```swift
// Sources/PastefixCore/Deadline.swift
import Foundation

/// The one sanctioned way to put a wall-clock bound on work that may not honour cancellation.
///
/// `run` returns to its caller at the deadline *whatever the body does*: a structured task group
/// cannot do that, because it awaits every child before returning (Plan 12 measured a 3 s
/// sleeper unblocking its caller at 10.9 s). The price is honesty about what a timeout means: the
/// body task is cancelled, and a body that checks `Task.isCancelled` stops, but a body inside an
/// uninterruptible Foundation call runs to completion in the background with its result
/// discarded. Input caps, not this helper, are the bound on that work.
public enum Deadline {
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        let work = Task.detached(priority: priority) {
            let outcome: Result<T, any Error>
            do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
            gate.finish(outcome)
        }
        let sleeper = Task.detached(priority: priority) {
            try? await Task.sleep(for: .seconds(seconds), clock: .continuous)
            guard !Task.isCancelled else { return }
            work.cancel()
            gate.finish(.failure(TransformError.timeout))
        }
        defer { sleeper.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                gate.arm(continuation)
            }
        } onCancel: {
            work.cancel()
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Resumes a continuation exactly once, whichever of body / sleeper / cancellation gets
    /// there first, and remembers an outcome that arrives before the continuation is armed
    /// (a caller cancelled before `withCheckedThrowingContinuation` ran).
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var pending: Result<T, any Error>?
        private var done = false

        func arm(_ c: CheckedContinuation<T, any Error>) {
            let ready: Result<T, any Error>? = lock.withLock {
                if let p = pending { pending = nil; done = true; return p }
                continuation = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }

        func finish(_ r: Result<T, any Error>) {
            let c: CheckedContinuation<T, any Error>? = lock.withLock {
                if done { return nil }
                if let c = continuation { continuation = nil; done = true; return c }
                if pending == nil { pending = r }
                return nil
            }
            c?.resume(with: r)
        }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter "DeadlineTests|ByteLimitTests"` → all pass. Then `swift test 2>&1 | tail -1` → 438 + 8 pass.

- [ ] **Step 5: Commit** `feat(core): Deadline.run, ByteLimit, TransformLimits`

---

### Task 2: Transformer caps/timeouts, `URLFinder` bound, presets adopt `Deadline.run` (Core, TDD)

**Files:** Modify `Sources/PastefixCore/Transformer.swift`, `Detection/URLFinder.swift`, `Detection/ContentDetector.swift` (doc only), `Native/MarkdownToRich.swift`, `Native/URLCleaner.swift`, `Native/MarkdownLink.swift`, `Native/RedactSecrets.swift`, `Native/RegexPresetTransformer.swift`, `Scripting/ShellTransformer.swift`, `Scripting/JSTransformer.swift`. Tests: create `Tests/PastefixCoreTests/TransformerLimitsTests.swift`; extend `URLFinderTests.swift`.

**Interfaces produced:** `Transformer.maxInputBytes: Int`, `Transformer.timeout: TimeInterval` (both with defaults); `URLFinder.maxBytes`.

- [ ] **Step 1: Failing tests**

```swift
// Tests/PastefixCoreTests/TransformerLimitsTests.swift
import Testing
import Foundation
@testable import PastefixCore

private struct Bare: Transformer {
    let id = "t.bare"; let name = "Bare"; let requiresRichInput = false
    let source = TransformerSource.builtin
    func apply(_ i: TransformInput) async throws -> String { i.text }
}

@Suite struct TransformerLimitsTests {
    @Test func defaultsApplyToAConformerThatDeclaresNothing() {
        #expect(Bare().maxInputBytes == TransformLimits.defaultMaxInputBytes)
        #expect(Bare().timeout == TransformLimits.defaultTimeout)
    }

    @Test func everyRegisteredTransformerDeclaresTheSpecTable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let preset = RegexPreset(name: "p", pattern: "a", replacement: "b")
        let all = TransformerRegistry(config: RegistryConfig(scriptsDirectory: dir, presets: [preset])).load()
        #expect(all.count >= 28)
        let table: [String: (bytes: Int, seconds: TimeInterval)] = [
            "builtin.markdowntorich": (65_536, 3),
            "builtin.urlclean": (262_144, 3),
            "builtin.markdownlink": (262_144, 6),
            "builtin.redactsecrets": (262_144, 3),
            RegexPresetTransformer.transformerID(for: preset.id): (262_144, 3),
        ]
        for t in all {
            let expected = table[t.id] ?? (TransformLimits.defaultMaxInputBytes, TransformLimits.defaultTimeout)
            #expect(t.maxInputBytes == expected.bytes, "\(t.id) maxInputBytes")
            #expect(t.timeout == expected.seconds, "\(t.id) timeout")
        }
    }

    @Test func markdownLinkTimeoutTracksItsFetchTimeout() {
        #expect(MarkdownLink(fetchTimeout: 1).timeout == 3)
    }
}
```

```swift
// Tests/PastefixCoreTests/URLFinderTests.swift — append inside the suite
    @Test func overCapReturnsNothing() {
        let unit = "https://example.com/p?x=1 "
        let atCap = String(repeating: unit, count: URLFinder.maxBytes / unit.utf8.count)
        #expect(atCap.utf8.count <= URLFinder.maxBytes)
        #expect(!URLFinder.find(in: atCap).isEmpty)
        let over = atCap + String(repeating: "a", count: URLFinder.maxBytes - atCap.utf8.count + 1)
        #expect(over.utf8.count > URLFinder.maxBytes)
        #expect(URLFinder.find(in: over).isEmpty)
    }

    @Test func cancelledTaskStopsEnumerationEarly() async {
        let text = String(repeating: "https://example.com/path?x=1 ", count: 8_000) // ~232 KB
        #expect(URLFinder.find(in: text).count == 8_000)
        let n = await Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return URLFinder.find(in: text).count
        }.value
        #expect(n < 8_000)
    }
```

- [ ] **Step 2: Run** `swift test --filter "TransformerLimitsTests|URLFinderTests"` → compile failure.

- [ ] **Step 3: Implement**

`Transformer.swift` — add to the protocol after `category` and to the default extension:

```swift
    /// Largest `TransformInput.text` (UTF-8 bytes) this transform accepts. The coordinator
    /// refuses larger buffers before calling `apply`, so a body need not re-check unless it is
    /// also reachable outside the coordinator (presets' Settings preview, for one).
    var maxInputBytes: Int { get }
    /// Wall-clock budget for `apply`, enforced by the coordinator through `Deadline.run`. A body
    /// that can be interrupted should check `Task.isCancelled`; one that cannot relies on
    /// `maxInputBytes` to keep it short.
    var timeout: TimeInterval { get }
```
```swift
public extension Transformer {
    var applicableKinds: Set<ContentKind>? { nil }
    var category: String? { nil }
    var maxInputBytes: Int { TransformLimits.defaultMaxInputBytes }
    var timeout: TimeInterval { TransformLimits.defaultTimeout }
}
```

Overrides:
- `MarkdownToRich`: `public let maxInputBytes = 65_536` with the comment `// Same MarkdownHTML.render pipeline MarkdownPreview caps at 16 KB for display; ~1.1 s at 64 KB of list-heavy input (Plan 10 measurement) is the most the 3 s budget should be asked to cover.`
- `URLCleaner`, `MarkdownLink`: `public var maxInputBytes: Int { URLFinder.maxBytes }`.
- `MarkdownLink`: `public var timeout: TimeInterval { fetchTimeout + 2 }` with the comment `// One batch of fetches bounded by fetchTimeout, plus margin for the local scan and title parse.`
- `RedactSecrets`: `public var maxInputBytes: Int { SecretDetector.maxBytes }` (keep the internal guard and message).
- `RegexPresetTransformer`: `public var maxInputBytes: Int { Self.maxBytes }` and `public var timeout: TimeInterval { Self.timeout }` (the static stays).
- `ShellTransformer`, `JSTransformer`: `private let timeout` → `public let timeout: TimeInterval`.

`URLFinder.swift`:

```swift
enum URLFinder {
    /// NSDataDetector costs ~1.75 s per MB (issue #28) and runs from detection, `URLCleaner`
    /// and `MarkdownLink`; bounding it here bounds all three. Matches `SecretDetector.maxBytes`.
    static let maxBytes = 262_144
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Empty over `maxBytes`. Stops early when the calling task is cancelled — the partial list
    /// is only ever seen by a caller about to discard it.
    static func find(in text: String) -> [FoundURL] {
        guard text.utf8.count <= maxBytes else { return [] }
        let ns = text as NSString
        var out: [FoundURL] = []
        // `.reportProgress` has the block called during long attempts, not only on matches, so
        // cancellation is observable mid-scan (the Plan 12 lesson, applied to the detector).
        detector.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match, var range = Range(match.range, in: text) else { return }
            // …existing trimming / scheme / URL construction body, with `continue` → `return`…
            out.append(FoundURL(range: range, url: url, original: original))
        }
        return out
    }
```

`ContentDetector.swift` doc: replace the `maxBytes` comment with: `/// Buffers larger than this are not inspected. Detection now runs off the main actor (Plan 14), so this bounds work, not summon latency. Note the URL rule has its own tighter bound: `.url` is never reported above `URLFinder.maxBytes` (256 KB) even though the other rules run to 1 MB.`

`RegexPresetTransformer.apply`:

```swift
    public func apply(_ input: TransformInput) async throws -> String {
        try Self.checkInputSize(input.text)
        let preset = self.preset, text = input.text
        let deadline = ContinuousClock.now + .seconds(Self.timeout)
        // `Deadline.run` unblocks the caller at the deadline whatever the pattern does and cancels
        // the worker; the in-block check below (reachable via `.reportProgress`) is what actually
        // stops the pattern, on either the deadline or that cancellation.
        return try await Deadline.run(seconds: Self.timeout) {
            try Self.replace(text, preset: preset, deadline: deadline).output
        }
    }
```
and in `replace`'s block: `if Task.isCancelled || (deadline.map { ContinuousClock.now > $0 } ?? false) { timedOut = true; stop.pointee = true; return }`. Update the type's header comment to point at `Deadline.run` instead of "see `apply` on what the timeout race can and cannot do".

- [ ] **Step 4: Run** `swift test 2>&1 | tail -1` → all pass (existing `RegexPresetTests` deadline tests included).

- [ ] **Step 5: Commit** `feat(core): per-transformer input caps and timeouts; URLFinder bound and cancellation; presets use Deadline.run`

---

### Task 3: `PasteDocument` detection state (AppCore, TDD)

**Files:** Create `Sources/PastefixAppCore/DetectionResult.swift`; Modify `Sources/PastefixAppCore/PasteDocument.swift`; Tests modify `Tests/PastefixAppCoreTests/PasteDocumentTests.swift`, `TransformCoordinatorTests.swift` (lines 61–66 only, see Step 3).

**Interfaces produced:** `DetectionResult { kinds, secretMatches, secretScanSkipped; static compute(_:) }`, `DetectionState { pending, complete(DetectionResult) }`, `PasteDocument.detection`, `.detectionRevision`, `.isDetecting`, `mutating applyDetection(_:revision:) -> Bool`.

- [ ] **Step 1: Failing tests** — replace `detectedKindsTrackWorkingText`, `secretMatchesPinnedAtDiscreteEvents`, `oversizeBufferIsFlaggedUnscannedNotClean` with:

```swift
    /// Runs the scan the scheduler would and installs it, as the app does after each event.
    private func settle(_ d: inout PasteDocument) {
        #expect(d.applyDetection(DetectionResult.compute(d.working), revision: d.detectionRevision))
    }

    @Test func startsPendingAndSettlesToKinds() {
        var d = doc("https://example.com")
        #expect(d.isDetecting && d.detectionRevision == 0 && d.detectedKinds.isEmpty)
        settle(&d)
        #expect(!d.isDetecting && d.detectedKinds == [.url])
    }

    @Test func discreteEventsBumpRevisionAndResetToPending() {
        var d = doc("https://example.com"); settle(&d)
        d.pushState("{\"a\":1}")
        #expect(d.isDetecting && d.detectionRevision == 1 && d.detectedKinds.isEmpty)
        settle(&d); #expect(d.detectedKinds == [.json])
        d.undo();   #expect(d.isDetecting && d.detectionRevision == 2)
        settle(&d); #expect(d.detectedKinds == [.url])
        d.redo();   #expect(d.detectionRevision == 3)
        settle(&d); #expect(d.detectedKinds == [.json])
        d.setWorking("plain")                       // manual edit: no event
        #expect(!d.isDetecting && d.detectionRevision == 3 && d.detectedKinds == [.json])
        d.pushState("plain")                        // equal text is still an event
        #expect(d.isDetecting && d.detectionRevision == 4)
        d.refresh(origin: ClipboardSnapshot(plainText: "www.example.com", richRTFD: nil))
        #expect(d.isDetecting && d.detectionRevision == 0)
    }

    @Test func staleRevisionIsRefused() {
        var d = doc("https://example.com")
        let old = DetectionResult.compute(d.working)
        d.pushState("{\"a\":1}")
        #expect(!d.applyDetection(old, revision: 0))
        #expect(d.isDetecting && d.detectedKinds.isEmpty)
        settle(&d)
        #expect(d.detectedKinds == [.json])
        #expect(!d.applyDetection(old, revision: 1), "a settled revision does not take a second result")
    }

    @Test func secretsAndSkipFlagComeFromTheResult() {
        var d = doc("AKIAIOSFODNN7EXAMPLE")
        #expect(d.secretMatches.isEmpty && !d.secretScanSkipped, "pending is neither found nor skipped")
        settle(&d)
        #expect(d.secretMatches.map(\.kind) == [.awsAccessKey] && d.detectedKinds.contains(.secret))
        let big = String(repeating: "a", count: SecretDetector.maxBytes) + " AKIAIOSFODNN7EXAMPLE"
        d.pushState(big); settle(&d)
        #expect(d.secretScanSkipped && d.secretMatches.isEmpty && !d.detectedKinds.contains(.secret))
    }

    @Test func computeMatchesTheOldInlineScan() {
        let r = DetectionResult.compute("see https://example.com and AKIAIOSFODNN7EXAMPLE")
        #expect(r.kinds == [.url, .secret] && r.secretMatches.count == 1 && !r.secretScanSkipped)
        #expect(DetectionResult.compute("").kinds.isEmpty)
    }
```

- [ ] **Step 2: Run** `swift test --filter PasteDocumentTests` → compile failure.

- [ ] **Step 3: Implement**

```swift
// Sources/PastefixAppCore/DetectionResult.swift
import Foundation
import PastefixCore

/// What one scan of a buffer found. Pure and synchronous: the scheduler runs `compute` off the
/// main actor and the document installs the result by revision.
public struct DetectionResult: Sendable, Equatable {
    public let kinds: Set<ContentKind>
    public let secretMatches: [SecretMatch]
    /// True when the text was over `SecretDetector.maxBytes`, so `secretMatches` is empty for
    /// want of a scan rather than for want of secrets.
    public let secretScanSkipped: Bool

    public init(kinds: Set<ContentKind>, secretMatches: [SecretMatch], secretScanSkipped: Bool) { … }

    /// The one place the secret scan and content detection are paired, so the scan runs once for
    /// both consumers. Never call on the main actor for session text (Plan 14).
    public static func compute(_ text: String) -> DetectionResult {
        let secrets = SecretDetector.scan(text)
        return DetectionResult(kinds: ContentDetector.detect(text, secrets: secrets),
                               secretMatches: secrets,
                               secretScanSkipped: !SecretDetector.isScannable(text))
    }
}

public enum DetectionState: Sendable, Equatable {
    case pending
    case complete(DetectionResult)
}
```

`PasteDocument.swift` — replace the three stored detection properties and `redetect()`:

```swift
    /// Detection for `working`. Pending after every discrete event (init, push, undo, redo,
    /// refresh) until the scheduler delivers a result for `detectionRevision`; the struct never
    /// scans on its own, because every caller is on the main actor.
    public private(set) var detection: DetectionState = .pending
    /// Incremented on every event that invalidates `detection`. A result carries the revision it
    /// was computed for and is refused if the document has moved on.
    public private(set) var detectionRevision = 0

    public var isDetecting: Bool { if case .pending = detection { return true } else { return false } }
    public var detectedKinds: Set<ContentKind> { if case .complete(let r) = detection { return r.kinds } else { return [] } }
    public var secretMatches: [SecretMatch] { if case .complete(let r) = detection { return r.secretMatches } else { return [] } }
    /// False while pending: an unscanned-yet buffer is not the same as an over-cap one, and the
    /// grey badge is for the latter.
    public var secretScanSkipped: Bool { if case .complete(let r) = detection { return r.secretScanSkipped } else { return false } }

    /// Installs `result` if it was computed for the current revision and nothing has been
    /// installed for it yet. Returns whether it applied.
    @discardableResult
    public mutating func applyDetection(_ result: DetectionResult, revision: Int) -> Bool {
        guard revision == detectionRevision, isDetecting else { return false }
        detection = .complete(result)
        return true
    }

    private mutating func invalidateDetection() {
        detection = .pending
        detectionRevision += 1
    }
```
`init` sets `detection = .pending`, `detectionRevision = 0` (no scan). `pushState`, `undo`, `redo` call `invalidateDetection()` where they called `redetect()`. Update the `pushState` doc comment ("still redetects" → "still invalidates detection: a push is a discrete event even when it lands on text a prior `setWorking` already coalesced in, so the scheduler resyncs to what's actually working"). `refresh` unchanged (new struct → revision 0).

`TransformCoordinatorTests.swift` lines 61–66: where the test asserts `updated.secretMatches.count == 1` / `.detectedKinds.contains(.secret)` after an apply, first settle: `var settled = updated; settled.applyDetection(DetectionResult.compute(settled.working), revision: settled.detectionRevision)` and assert on `settled`; also assert `updated.isDetecting`.

- [ ] **Step 4: Run** `swift test 2>&1 | tail -1` → all pass.

- [ ] **Step 5: Commit** `feat(appcore): PasteDocument carries a pending/complete detection state; no inline scanning`

---

### Task 4: `DetectionScheduler` (AppCore, TDD)

**Files:** Create `Sources/PastefixAppCore/DetectionScheduler.swift`; Tests create `Tests/PastefixAppCoreTests/DetectionSchedulerTests.swift`.

**Interfaces consumed:** `DetectionResult.compute`. **Produced:** `DetectionScheduler` (`@MainActor final class`), `DetectionScheduler.Request`, `request(_:)`, `cancelAll()`.

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
import PastefixCore
@testable import PastefixAppCore

/// Records which texts the injected scan ran for, from detached tasks.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var value: [String] { lock.withLock { items } }
    func add(_ s: String) { lock.withLock { items.append(s) } }
}

@MainActor
private func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }

private func slowScan(_ log: Log, sleep: TimeInterval = 0.15) -> @Sendable (String) -> DetectionResult {
    { text in log.add(text); Thread.sleep(forTimeInterval: sleep); return DetectionResult.compute(text) }
}

@Suite @MainActor struct DetectionSchedulerTests {
    @Test func deliversWithTheOriginatingRequest() async {
        var delivered: [(DetectionScheduler.Request, DetectionResult)] = []
        let s = DetectionScheduler(compute: DetectionResult.compute) { delivered.append(($0, $1)) }
        s.request(.init(text: "https://example.com", revision: 3, generation: 7))
        await settle(0.3)
        #expect(delivered.count == 1)
        #expect(delivered.first?.0.revision == 3 && delivered.first?.0.generation == 7)
        #expect(delivered.first?.1.kinds == [.url])
    }

    @Test func aBurstRunsFirstAndLastOnlyAndDeliversOnlyTheLast() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.request(.init(text: "B", revision: 1, generation: 1))
        s.request(.init(text: "C", revision: 2, generation: 1))
        await settle()
        #expect(log.value == ["A", "C"], "B was displaced before it started; A was cancelled but could not be stopped")
        #expect(delivered == ["C"])
    }

    @Test func aFinishedScanIsDeliveredWhenNothingDisplacedIt() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log, sleep: 0.05)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        await settle(0.3)
        s.request(.init(text: "B", revision: 1, generation: 1))
        await settle(0.3)
        #expect(delivered == ["A", "B"])
    }

    @Test func cancelAllDeliversNothing() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.request(.init(text: "B", revision: 1, generation: 1))
        s.cancelAll()
        await settle()
        #expect(delivered.isEmpty)
        #expect(log.value == ["A"], "the waiting request never starts")
    }

    @Test func requestAfterCancelAllRunsFresh() async {
        let log = Log()
        var delivered: [String] = []
        let s = DetectionScheduler(compute: slowScan(log, sleep: 0.05)) { req, _ in delivered.append(req.text) }
        s.request(.init(text: "A", revision: 0, generation: 1))
        s.cancelAll()
        s.request(.init(text: "B", revision: 0, generation: 2))
        await settle(0.4)
        #expect(delivered == ["B"])
    }
}
```

- [ ] **Step 2: Run** `swift test --filter DetectionSchedulerTests` → compile failure.

- [ ] **Step 3: Implement**

```swift
// Sources/PastefixAppCore/DetectionScheduler.swift
import Foundation
import PastefixCore

/// Runs `DetectionResult.compute` off the main actor, one scan at a time, and delivers results
/// back on it.
///
/// Single slot, not a queue: a request that arrives while a scan runs replaces whatever was
/// waiting and cancels the running scan (`URLFinder` observes cancellation; the other rules are
/// fast). Queueing would let rapid undo/redo stack 1 MB scans — the `TIFFConversionSlot` lesson.
/// A cancelled scan's result is discarded; so is a finished scan's when something newer is
/// waiting, because the document it describes is already gone.
@MainActor
public final class DetectionScheduler {
    public struct Request: Sendable {
        public let text: String
        public let revision: Int
        public let generation: Int
        public init(text: String, revision: Int, generation: Int) { … }
    }

    private let compute: @Sendable (String) -> DetectionResult
    private let deliver: @MainActor (Request, DetectionResult) -> Void
    private var ticket = 0
    private var running: (ticket: Int, task: Task<Void, Never>)?
    private var waiting: Request?

    public init(compute: @escaping @Sendable (String) -> DetectionResult = DetectionResult.compute,
                deliver: @escaping @MainActor (Request, DetectionResult) -> Void) { … }

    public func request(_ req: Request) {
        if running == nil { start(req) } else { waiting = req; running?.task.cancel() }
    }

    public func cancelAll() {
        waiting = nil
        running?.task.cancel()
        running = nil
    }

    private func start(_ req: Request) {
        ticket += 1
        let mine = ticket
        let compute = self.compute
        let work = Task.detached(priority: .userInitiated) { compute(req.text) }
        let task = Task { [weak self] in
            // Cancelling the detached task is what lets `URLFinder` stop early; the await still
            // returns only when the scan returns, which is why the slot exists.
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            self?.finished(mine, req, result, cancelled: Task.isCancelled)
        }
        running = (mine, task)
    }

    private func finished(_ mine: Int, _ req: Request, _ result: DetectionResult, cancelled: Bool) {
        guard running?.ticket == mine else { return }   // cancelAll() already let go of this one
        running = nil
        if let next = waiting { waiting = nil; start(next); return }
        if !cancelled { deliver(req, result) }
    }
}
```

- [ ] **Step 4: Run** `swift test 2>&1 | tail -1` → all pass. Run `swift test --filter DetectionSchedulerTests` three times to confirm no flakiness.

- [ ] **Step 5: Commit** `feat(appcore): DetectionScheduler — single-slot off-main detection lane`

---

### Task 5: `TransformCoordinator` cap + deadline (AppCore, TDD)

**Files:** Modify `Sources/PastefixAppCore/TransformCoordinator.swift`; Tests extend `Tests/PastefixAppCoreTests/TransformCoordinatorTests.swift`.

**Interfaces consumed:** `Transformer.maxInputBytes`/`.timeout`, `Deadline.run`, `ByteLimit.describe`.

- [ ] **Step 1: Failing tests** — extend `FakeTransformer` with `var maxInputBytes = TransformLimits.defaultMaxInputBytes` and `var timeout: TimeInterval = TransformLimits.defaultTimeout`, then add:

```swift
    @Test func overCapIsRefusedBeforeApplyRuns() async {
        let ran = Flag()   // reuse the lock-guarded Flag pattern from DeadlineTests (copy it privately here)
        var t = FakeTransformer(id: "x", name: "Markdown → Rich Text", requiresRichInput: false) { _ in ran.raise(); return "" }
        t.maxInputBytes = 65_536
        let (updated, outcome) = await TransformCoordinator.apply(t, to: doc(String(repeating: "a", count: 65_537)))
        #expect(outcome == .failed("Markdown → Rich Text is limited to 64 KB of text."))
        #expect(!ran.value && updated.canUndo == false)
    }

    @Test func exactlyAtCapRuns() async {
        var t = FakeTransformer(id: "x", name: "X", requiresRichInput: false) { $0.text.uppercased() }
        t.maxInputBytes = 4
        let (_, outcome) = await TransformCoordinator.apply(t, to: doc("abcd"))
        #expect(outcome == .applied)
    }

    @Test func slowTransformTimesOutAtItsOwnBudget() async {
        var t = FakeTransformer(id: "x", name: "X", requiresRichInput: false) { i in
            Thread.sleep(forTimeInterval: 1.0); return i.text
        }
        t.timeout = 0.2
        let start = ContinuousClock.now
        let (_, outcome) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(outcome == .failed("The transform timed out."))
        #expect(ContinuousClock.now - start < .seconds(0.8))
    }

    @Test func cancelledCallerGetsCancelledOutcome() async {
        let t = FakeTransformer(id: "x", name: "X", requiresRichInput: false) { i in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return i.text
        }
        let outer = Task { await TransformCoordinator.apply(t, to: doc("hi")) }
        try? await Task.sleep(for: .milliseconds(50))
        outer.cancel()
        let (_, outcome) = await outer.value
        #expect(outcome == .failed("The transform was cancelled."))
    }

    @Test func appliedDocumentIsPendingDetectionAtTheNextRevision() async {
        let t = FakeTransformer(id: "x", name: "X", requiresRichInput: false) { $0.text.uppercased() }
        let (updated, _) = await TransformCoordinator.apply(t, to: doc("hi"))
        #expect(updated.isDetecting && updated.detectionRevision == 1)
    }
```

- [ ] **Step 2: Run** `swift test --filter TransformCoordinatorTests` → failures.

- [ ] **Step 3: Implement** — in `apply(_:to:)`:

```swift
        var doc = document
        let input = TransformInput(text: doc.working, richRTFD: doc.origin.richRTFD)
        // Refuse before running: the cap is the only bound on a body inside an uninterruptible
        // Foundation call, and the user is told the limit rather than watching a spinner.
        guard input.text.utf8.count <= transformer.maxInputBytes else {
            return (doc, .failed("\(transformer.name) is limited to \(ByteLimit.describe(transformer.maxInputBytes)) of text."))
        }
        do {
            // Off the calling actor and abandoned at the transform's own deadline; a native body
            // awaited inline here used to block the main actor for its full duration.
            let result = try await Deadline.run(seconds: transformer.timeout) { try await transformer.apply(input) }
            …existing arming / outcome / pushState…
        } catch let error as TransformError {
            return (doc, .failed(message(for: error)))
        } catch is CancellationError {
            return (doc, .failed("The transform was cancelled."))
        } catch {
            return (doc, .failed(error.localizedDescription))
        }
```
Update the comment above the outcome/push: `pushState` now marks detection pending and bumps the revision (the model requests the scan), which is still the only thing that resyncs kinds after a manual `setWorking` edit.

- [ ] **Step 4: Run** `swift test 2>&1 | tail -1` → all pass.

- [ ] **Step 5: Commit** `feat(appcore): coordinator enforces maxInputBytes and runs apply under Deadline.run`

---

### Task 6: App wiring (app target)

**Files:** Modify `Pastefix/Pastefix/AppModel.swift`. No `PanelView` change is required (badges already hide on empty/nil).

**Interfaces consumed:** `DetectionScheduler`, `PasteDocument.isDetecting/detectionRevision/applyDetection`.

- [ ] **Step 1: Implement**

Properties:
```swift
    /// Off-main detection lane; results land through `detectionFinished`.
    private lazy var detection = DetectionScheduler { [weak self] req, result in self?.detectionFinished(req, result) }
    /// The in-flight apply, cancelled wherever the session changes so a slow transform does not
    /// keep running for a buffer nobody can see.
    private var applyTask: Task<Void, Never>?

    /// True until the current buffer's scan lands. The Zipline upload gate (#14) must wait for
    /// this before treating an empty `secretMatches` as "no secrets".
    var isDetecting: Bool { document?.isDetecting ?? false }
```

Helpers:
```swift
    private func requestDetection() {
        guard let doc = document, doc.isDetecting else { return }
        detection.request(.init(text: doc.working, revision: doc.detectionRevision, generation: sessionGeneration))
    }

    private func detectionFinished(_ req: DetectionScheduler.Request, _ result: DetectionResult) {
        guard sessionGeneration == req.generation, var doc = document else { return }
        if doc.applyDetection(result, revision: req.revision) { document = doc }
    }

    /// Stops work that belonged to the buffer being replaced.
    private func abandonInFlightWork() {
        applyTask?.cancel()
        applyTask = nil
        detection.cancelAll()
        isApplying = false
    }
```

Call sites:
- `summon()` and `load(_:)`: call `abandonInFlightWork()` before `sessionGeneration &+= 1`; call `requestDetection()` after `document = …`.
- `refresh()`, `undo()`, `redo()`: `requestDetection()` after `document = doc`.
- `apply(_:)`: assign `applyTask = Task { … }`; inside, after `self.document = updated` call `self.requestDetection()`; in the stale branch (`guard self.document != nil, self.sessionGeneration == generation`) just `return` — `abandonInFlightWork()`/`endSession()` own `isApplying` now. At the end of the success path set `self.applyTask = nil`.
- `endSession()`: call `abandonInFlightWork()` first (it sets `isApplying = false`; keep the rest).

- [ ] **Step 2: Build** `xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug -derivedDataPath /tmp/pastefix-dd build 2>&1 | grep -E "error|warning: .*AppModel|BUILD" | head` → `BUILD SUCCEEDED`, no new warnings in `AppModel.swift`. Do not launch the app.

- [ ] **Step 3: Commit** `feat(app): request detection off-main per event; cancel apply and detection on session change`

---

### Task 7: Docs

**Files:** Modify `AGENTS.md`, `docs/specs/2026-09-23-pastefix-v2-large-buffer-safety.md`, `docs/specs/2026-08-11-pastefix-v2-foundation-pipeline.md`, `docs/specs/2026-09-20-pastefix-v2-content-transforms.md`.

- [ ] AGENTS status table: add `| 14 — Large-buffer safety | DetectionScheduler, Deadline.run, maxInputBytes/timeout | 🚧 in progress — branch feat/large-buffer-safety — [spec](…), [plan](…) |`.
- [ ] AGENTS file map: `DetectionResult.swift`, `DetectionScheduler.swift`, `Deadline.swift`, `ByteLimit.swift` one-liners.
- [ ] AGENTS Patterns: (a) "Session text is scanned off the main actor. `PasteDocument` never scans; `DetectionScheduler` runs `DetectionResult.compute` and results land by revision + generation. Never call `SecretDetector`/`ContentDetector` on the main actor for session text." (b) "Every transform declares `maxInputBytes` and `timeout`; the coordinator enforces both. A new transform whose cost is superlinear or that calls an uninterruptible API lowers its cap; one that can loop checks `Task.isCancelled`." (c) "`Deadline.run` is the only sanctioned deadline race; it abandons and cancels, it does not stop. Hand-rolled task-group races are not a bound."
- [ ] AGENTS "Things that have bitten us — Plan 14": inline `await transformer.apply` on the main actor's task ran synchronous bodies on the main actor; `JSRunner`-style races that resume the caller and leave the work running; `Cancel` that only discarded the result.
- [ ] Spec amendment: defaults live in `TransformLimits` (not `Transformer.defaultMaxInputBytes`).
- [ ] Foundation spec and content-transforms spec: one-line amendment notes pointing at this spec for detection timing and transform bounds.
- [ ] Commit `docs: Plan 14 status, patterns, spec amendments`.

---

### Task 8: GUI pass (controller, ask first) and finish

- [ ] Ask the user for the screen. Save the clipboard. Re-sign the Debug build with the Developer ID identity (memory: `resign-debug-for-tcc`).
- [ ] 1 MB URL-dense buffer on the pasteboard → summon → screenshot within 200 ms shows the panel; "Detected:" absent (over the URL cap). 900 KB JSON → summon → "Detected: JSON" appears within ~1 s.
- [ ] 2 MB Markdown buffer → ⌘K "Markdown → Rich Text" → banner `Markdown → Rich Text is limited to 64 KB of text.`
- [ ] 300 KB buffer with URLs → ⌘K "Clean URL Tracking" → banner with `256 KB`.
- [ ] A shell script transform that sleeps 10 s → apply → Esc → panel closes at once; re-summon is not `isApplying`; log shows no stuck spinner.
- [ ] Restore the clipboard. Final whole-branch review, PR closing #28 and #29, `git checkout main`.

## Self-review

- Spec coverage: §1 → Task 3; §2 → Task 4; §3 → Task 6; §4 → Task 2; §5 → Task 2; §6 → Task 1 (+ presets in Task 2); §7 → Task 5; §8 → Task 2; testing → per task; docs → Task 7; GUI → Task 8.
- Type consistency: `DetectionScheduler.Request(text:revision:generation:)` with `generation: Int` matches `AppModel.sessionGeneration` (`Int`); `applyDetection(_:revision:) -> Bool` used identically in Tasks 3, 5 and 6; `Deadline.run(seconds:priority:_:)` in Tasks 1, 2, 5; `ByteLimit.describe` in Tasks 1 and 5.
- Known plan defect to watch: the `RegexPreset(name:pattern:replacement:)` initialiser in Task 2's test has other defaulted parameters; use whatever the real signature requires.
