import Foundation

/// Runs a `RegexPreset`. User patterns are untrusted for cost: capped input, a deadline checked
/// during and between matches, and a hard timeout race so the panel never hangs (Plans 8/11 lessons).
public struct RegexPresetTransformer: Transformer {
    public static let maxBytes = 262_144
    public static let timeout: TimeInterval = 3
    public let preset: RegexPreset

    public init(preset: RegexPreset) { self.preset = preset }

    public var id: String { "preset:\(preset.id.uuidString)" }
    public var name: String { preset.name }
    public let requiresRichInput = false
    public var source: TransformerSource { .preset(preset.id) }
    public var category: String? { TransformCategory.presets }

    public func apply(_ input: TransformInput) async throws -> String {
        guard input.text.utf8.count <= Self.maxBytes else {
            throw TransformError.invalidInput("Text is too large for a regex preset (limit 256 KB)")
        }
        let preset = self.preset, text = input.text
        let deadline = ContinuousClock.now + .seconds(Self.timeout)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try Self.replace(text, preset: preset, deadline: deadline).output }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); throw TransformError.timeout }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Synchronous core. Throws `invalidInput` (bad pattern) or `timeout` (deadline passed).
    ///
    /// Returns the match count alongside the output because it already knows it — the Settings
    /// preview needs both, and a second counting pass would spend a second helping of the same
    /// deadline on work this one has already done.
    ///
    /// The deadline is observable *during* a match attempt as well as between matches, thanks to
    /// `.reportProgress` (see the comment below); the async race in `apply` is the backstop, not
    /// the only bound.
    static func replace(_ text: String, preset: RegexPreset,
                        deadline: ContinuousClock.Instant?) throws -> (output: String, matches: Int) {
        let regex = try preset.compile()
        let template = RegexPreset.expandEscapes(preset.replacement)
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var matches = 0
        var timedOut = false
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
            if !preset.replaceAll { stop.pointee = true }
        }
        if timedOut { throw TransformError.timeout }
        out += ns.substring(from: cursor)
        return (out, matches)
    }
}

extension RegexPresetTransformer {
    /// The Settings preview: the replaced text plus how many matches it replaced.
    ///
    /// Public because the preview is rendered from the app target, where `replace` — deliberately
    /// internal, since running a preset is `apply`'s job — isn't visible. One pass, one deadline:
    /// counting used to be a second `enumerateMatches` sharing the same absolute deadline, which
    /// halved the budget and threw away an output pass 1 had already computed correctly.
    public static func preview(_ text: String, preset: RegexPreset,
                               deadline: ContinuousClock.Instant) throws -> (output: String, matches: Int) {
        try replace(text, preset: preset, deadline: deadline)
    }
}
