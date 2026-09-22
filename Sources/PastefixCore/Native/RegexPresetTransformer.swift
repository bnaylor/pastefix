import Foundation

/// Runs a `RegexPreset`. User patterns are untrusted for cost, so the work is bounded three ways:
/// the input is capped, the output is capped (a zero-width pattern with a long replacement
/// amplifies without bound), and the deadline is checked *inside* the scan via `.reportProgress`
/// (Plans 8/11 lessons). The deadline check is the only thing that can actually stop a running
/// pattern — see `apply` on what the timeout race can and cannot do.
public struct RegexPresetTransformer: Transformer {
    public static let maxBytes = 262_144
    /// A replacement is applied per match, so output size is not bounded by input size: measured
    /// 1.2 GB peak RSS from pattern `(?:)` with a 4 KB replacement over a 256 KB input, inside the
    /// 3 s window. 8x the input cap is far more than any real find & replace produces.
    public static let maxOutputBytes = 8 * maxBytes
    public static let timeout: TimeInterval = 3
    public let preset: RegexPreset

    public init(preset: RegexPreset) { self.preset = preset }

    /// The transformer id a preset is surfaced under. A `static` as well as the instance
    /// property because `SettingsStore` has to build the same string to clear a removed preset's
    /// enable/order overrides, and two hand-written copies of an id format drift.
    public static func transformerID(for presetID: UUID) -> String { "preset:\(presetID.uuidString)" }

    public var id: String { Self.transformerID(for: preset.id) }
    public var name: String { preset.name }
    public let requiresRichInput = false
    public var source: TransformerSource { .preset(preset.id) }
    public var category: String? { TransformCategory.presets }

    public func apply(_ input: TransformInput) async throws -> String {
        try Self.checkInputSize(input.text)
        let preset = self.preset, text = input.text
        let deadline = ContinuousClock.now + .seconds(Self.timeout)
        // The sleeping task is a second error path, NOT a bound on the work. Structured
        // concurrency awaits every child before the group's error propagates, so a worker that
        // ignores its deadline keeps the caller blocked no matter when the sleeper fires
        // (measured: sleeper at 3.189 s, caller unblocked at 10.911 s, with a deadline-blind
        // copy of `replace`). What actually stops a runaway pattern is the in-block deadline
        // check below, which `.reportProgress` makes reachable; the race only guarantees that a
        // deadline observed slightly late still surfaces as `.timeout` at exactly 3 s.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try Self.replace(text, preset: preset, deadline: deadline).output }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); throw TransformError.timeout }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Synchronous core. Throws `invalidInput` (bad pattern, or output over the cap) or `timeout`
    /// (deadline passed).
    ///
    /// Returns the match count alongside the output because it already knows it — the Settings
    /// preview needs both, and a second counting pass would spend a second helping of the same
    /// deadline on work this one has already done.
    ///
    /// The deadline is observable *during* a match attempt as well as between matches, thanks to
    /// `.reportProgress`, and that is the only mechanism that stops a runaway pattern: the task
    /// group in `apply` cannot cut this function loose once it is running.
    static func replace(_ text: String, preset: RegexPreset,
                        deadline: ContinuousClock.Instant?) throws -> (output: String, matches: Int) {
        let regex = try preset.compile()
        let template = RegexPreset.expandEscapes(preset.replacement)
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var matches = 0
        var timedOut = false
        var overflowed = false
        // `.reportProgress` makes NSRegularExpression call the block periodically *during* a
        // long match attempt, not only on a match — without it a catastrophically backtracking
        // user pattern (e.g. `(a+)+$` against a non-matching run) spends minutes inside a single
        // attempt with the block never invoked, and the deadline would be unobservable here.
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            if let deadline, ContinuousClock.now > deadline { timedOut = true; stop.pointee = true; return }
            guard let m else { return }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += regex.replacementString(for: m, in: text, offset: 0, template: template)
            cursor = NSMaxRange(m.range)
            matches += 1
            // The deadline alone doesn't bound memory: three seconds of a zero-width pattern with
            // a long replacement is a gigabyte of string the caller then throws away.
            if out.utf8.count > Self.maxOutputBytes { overflowed = true; stop.pointee = true; return }
            if !preset.replaceAll { stop.pointee = true }
        }
        if timedOut { throw TransformError.timeout }
        if overflowed { throw TransformError.invalidInput("Replacement output is too large (limit 2 MB)") }
        out += ns.substring(from: cursor)
        return (out, matches)
    }

    static func checkInputSize(_ text: String) throws {
        guard text.utf8.count <= maxBytes else {
            throw TransformError.invalidInput("Text is too large for a regex preset (limit 256 KB)")
        }
    }
}

extension RegexPresetTransformer {
    /// The Settings preview: the replaced text plus how many matches it replaced.
    ///
    /// Public because the preview is rendered from the app target, where `replace` — deliberately
    /// internal, since running a preset is `apply`'s job — isn't visible. One pass, one deadline:
    /// counting used to be a second `enumerateMatches` sharing the same absolute deadline, which
    /// halved the budget and threw away an output pass 1 had already computed correctly.
    ///
    /// The input cap applies here too. The Settings sample is far smaller than 256 KB, but this
    /// is the second public door into `replace` and it shouldn't be the uncapped one.
    public static func preview(_ text: String, preset: RegexPreset,
                               deadline: ContinuousClock.Instant) throws -> (output: String, matches: Int) {
        try checkInputSize(text)
        return try replace(text, preset: preset, deadline: deadline)
    }
}
