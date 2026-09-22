# Pastefix v2 Regex Presets (Plan 12) — Implementation Plan

> ## 🟡 STATUS: IN PROGRESS — branch feat/regex-presets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; concurrency (Task 1's timed replace) → `swift-concurrency-pro`; SwiftUI (Task 3) → `swiftui-pro`. **TDD is required** for every package task. **One implementer at a time on the branch.** GUI passes are the controller's, with the user's permission.

**Goal:** User-defined regex find & replace rules, stored as settings, each a real transform in a "Presets" category, authored in a Presets settings tab with a live preview, and guarded by an input cap and a timeout.

**Architecture:** `PastefixCore` gains `RegexPreset` (model + compile + escape expansion), `RegexPresetTransformer` (capped, timed replace; `preset:<uuid>` ids; `.preset` source; Presets category), and registry support (order band 900). `PastefixAppCore` persists `regexPresets` in `SettingsStore`. The app passes presets to the registry, reloads on change, and adds the Presets settings tab.

**Tech Stack:** Swift 6 SwiftPM (macOS 14+), `NSRegularExpression`, structured concurrency (detached task + timeout race), Swift Testing, SwiftUI.

**Spec:** `docs/specs/2026-09-21-pastefix-v2-regex-presets.md` — read it first.

## Global Constraints

- **Ids/order/category:** transformer id `preset:<UUID uppercase>`, `source: .preset(id)`, `category: TransformCategory.presets` ("Presets", appended last to `builtinOrder`), registry order **900** name-sorted, between built-ins (≤ 110) and scripts (1000).
- **Safety:** input cap `262_144` bytes → `TransformError.invalidInput("Text is too large for a regex preset (limit 256 KB)")`; replace runs in `Task.detached` raced against a **3 s** sleep → `TransformError.timeout`; the synchronous core checks a `ContinuousClock` deadline between matches and throws `timeout`.
- **Template:** `NSRegularExpression` template syntax; `expandEscapes` turns `\n` → newline, `\t` → tab, `\\` → `\` before use (in that order, single pass, left to right).
- **Flags:** `caseInsensitive` → `.caseInsensitive`; `anchorsMatchLines` → `.anchorsMatchLines`; `dotMatchesNewlines` → `.dotMatchesLineSeparators`; `replaceAll` false → replace the first match only.
- **Settings:** `regexPresets: [RegexPreset]`, key `pastefix.regexPresets`, JSON, default `[]`; `addPreset`, `updatePreset`, `removePreset(id:)`.
- **Preview in Settings:** 16 KB cap, 1 s deadline, 200 ms debounce, shows "n match(es)" or the error.
- **Branch:** `feat/regex-presets`. Conventional commits + `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #12. `main` is protected.

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/regex-presets && swift test 2>&1 | tail -1` → `413 tests in 49 suites passed`.

---

### Task 1: Model, transformer, registry (Core, TDD)

**Files:** Create `Sources/PastefixCore/RegexPreset.swift`, `Native/RegexPresetTransformer.swift`; Modify `Transformer.swift` (source case, category), `Discovery/TransformerRegistry.swift` (config field, emission); Tests `Tests/PastefixCoreTests/RegexPresetTests.swift` (new), `TransformerRegistryTests.swift` (extend).

- [ ] **Step 1: Failing tests**
```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite struct RegexPresetTests {
    func run(_ p: RegexPreset, _ text: String) async throws -> String {
        try await RegexPresetTransformer(preset: p).apply(TransformInput(text: text))
    }
    @Test func groupsAndTemplate() async throws {
        let p = RegexPreset(name: "swap", pattern: #"(\w+) (\w+)"#, replacement: "$2 $1")
        #expect(try await run(p, "hello world") == "world hello")
    }
    @Test func escapesInReplacement() async throws {
        let p = RegexPreset(name: "nl", pattern: ", ", replacement: #"\n"#)
        #expect(try await run(p, "a, b, c") == "a\nb\nc")
        #expect(RegexPreset.expandEscapes(#"\\n"#) == #"\n"#)      // escaped backslash stays literal
        #expect(RegexPreset.expandEscapes(#"x\ty"#) == "x\ty")
    }
    @Test func flags() async throws {
        #expect(try await run(RegexPreset(name: "ci", pattern: "abc", replacement: "X", caseInsensitive: true), "ABC abc") == "X X")
        #expect(try await run(RegexPreset(name: "anch", pattern: "^b", replacement: "X", anchorsMatchLines: true), "a\nb") == "a\nX")
        #expect(try await run(RegexPreset(name: "noanch", pattern: "^b", replacement: "X", anchorsMatchLines: false), "a\nb") == "a\nb")
        #expect(try await run(RegexPreset(name: "dot", pattern: "a.b", replacement: "X", dotMatchesNewlines: true), "a\nb") == "X")
        #expect(try await run(RegexPreset(name: "first", pattern: "o", replacement: "0", replaceAll: false), "foo boo") == "f0o boo")
    }
    @Test func invalidPatternThrows() async {
        let p = RegexPreset(name: "bad", pattern: "(", replacement: "")
        await #expect(throws: TransformError.self) { try await run(p, "x") }
        #expect(throws: TransformError.self) { try p.compile() }
    }
    @Test func inputCap() async {
        let p = RegexPreset(name: "any", pattern: "a", replacement: "b")
        await #expect(throws: TransformError.invalidInput("Text is too large for a regex preset (limit 256 KB)")) {
            try await run(p, String(repeating: "a", count: RegexPresetTransformer.maxBytes + 1))
        }
    }
    @Test func deadlineIsHonoured() throws {
        let evil = RegexPreset(name: "evil", pattern: "(a+)+$", replacement: "x")
        let text = String(repeating: "a", count: 28) + "!"
        let start = ContinuousClock.now
        #expect(throws: TransformError.timeout) {
            try RegexPresetTransformer.replace(text, preset: evil, deadline: start + .milliseconds(50))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
    @Test func identity() {
        let p = RegexPreset(name: "n", pattern: "a", replacement: "b")
        let t = RegexPresetTransformer(preset: p)
        #expect(t.id == "preset:\(p.id.uuidString)" && t.name == "n" && t.category == TransformCategory.presets && t.source == .preset(p.id) && !t.requiresRichInput)
    }
}
```
Append to `TransformerRegistryTests`:
```swift
    @Test func presetsSitBetweenBuiltinsAndScripts() {
        let a = RegexPreset(name: "Zed", pattern: "z", replacement: ""), b = RegexPreset(name: "Alpha", pattern: "a", replacement: "")
        let cfg = RegistryConfig(scriptsDirectory: URL(fileURLWithPath: "/nonexistent"), wrapWidth: 80, presets: [a, b])
        let ids = TransformerRegistry(config: cfg).load().map(\.id)
        #expect(ids.suffix(2) == ["preset:\(b.id.uuidString)", "preset:\(a.id.uuidString)"])   // name-sorted, after every built-in
        #expect(TransformCategory.builtinOrder.last == TransformCategory.presets)
    }
```
- [ ] **Step 2:** `swift test --filter "RegexPresetTests|TransformerRegistryTests"` → compile errors.
- [ ] **Step 3: Implement**

`RegexPreset.swift`:
```swift
import Foundation

/// A user-defined find & replace rule. Stored as settings JSON; surfaced as a transform.
public struct RegexPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    public var caseInsensitive: Bool
    public var anchorsMatchLines: Bool
    public var dotMatchesNewlines: Bool
    public var replaceAll: Bool

    public init(id: UUID = UUID(), name: String, pattern: String, replacement: String = "",
                caseInsensitive: Bool = false, anchorsMatchLines: Bool = true,
                dotMatchesNewlines: Bool = false, replaceAll: Bool = true) { … }

    public var regexOptions: NSRegularExpression.Options {
        var o: NSRegularExpression.Options = []
        if caseInsensitive { o.insert(.caseInsensitive) }
        if anchorsMatchLines { o.insert(.anchorsMatchLines) }
        if dotMatchesNewlines { o.insert(.dotMatchesLineSeparators) }
        return o
    }

    public func compile() throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern, options: regexOptions) }
        catch { throw TransformError.invalidInput("Invalid pattern: \(error.localizedDescription)") }
    }

    /// `\n` → newline, `\t` → tab, `\\` → `\`; single left-to-right pass so `\\n` stays `\n` literally.
    public static func expandEscapes(_ template: String) -> String {
        var out = ""; var it = template.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\\": out.append("\\")
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }
}
```
`Transformer.swift`: `case preset(UUID)` in `TransformerSource`; `TransformCategory.presets = "Presets"`; `builtinOrder` += `[presets]` at the end. Fix any exhaustive `switch` over `TransformerSource` (grep).

`RegexPresetTransformer.swift`:
```swift
import Foundation

/// Runs a `RegexPreset`. User patterns are untrusted for cost: capped input, a deadline checked
/// between matches, and a hard timeout race so the panel never hangs (Plans 8/11 lessons).
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
            group.addTask { try Self.replace(text, preset: preset, deadline: deadline) }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); throw TransformError.timeout }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Synchronous core. Throws `invalidInput` (bad pattern) or `timeout` (deadline passed between matches).
    static func replace(_ text: String, preset: RegexPreset, deadline: ContinuousClock.Instant?) throws -> String {
        let regex = try preset.compile()
        let template = RegexPreset.expandEscapes(preset.replacement)
        let ns = text as NSString
        var out = ""; var cursor = 0; var timedOut = false; var replaced = 0
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            if let deadline, ContinuousClock.now > deadline { timedOut = true; stop.pointee = true; return }
            guard let m else { return }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += regex.replacementString(for: m, in: text, offset: 0, template: template)
            cursor = NSMaxRange(m.range); replaced += 1
            if !preset.replaceAll { stop.pointee = true }
        }
        if timedOut { throw TransformError.timeout }
        out += ns.substring(from: cursor)
        return out
    }
}
```
Note on the deadline test: catastrophic patterns backtrack *inside* one match attempt, where the block isn't called; the `deadlineIsHonoured` test uses a 28-char input so the single attempt finishes in well under 2 s and the block's deadline check then fires. If on this machine the `(a+)+$` attempt at 28 chars completes before 50 ms, raise the input length until the assertion holds and note the measured time; the async `apply` race is what protects the app for the truly pathological case.

Registry: `RegistryConfig.presets: [RegexPreset] = []` (new init parameter with default); in `load()` after built-ins: `for p in config.presets.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { entries.append((900, p.name, RegexPresetTransformer(preset: p))) }`.
- [ ] **Step 4:** filters green; full suite green (update registry pins if any assert the full id list).
- [ ] **Step 5: Commit** `feat(core): RegexPreset + RegexPresetTransformer (capped, timed), Presets category, registry band 900`.

---

### Task 2: Settings persistence (AppCore, TDD)

**Files:** Modify `Sources/PastefixAppCore/SettingsStore.swift`; Test `SettingsStoreTests` (extend).

- [ ] Tests:
```swift
    @Test func regexPresetsRoundTrip() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.regexPresets.isEmpty)
            let p = RegexPreset(name: "n", pattern: "a", replacement: "b")
            s.addPreset(p)
            var q = p; q.name = "renamed"; s.updatePreset(q)
            #expect(SettingsStore(defaults: d).regexPresets == [q])
            s.removePreset(id: p.id)
            #expect(SettingsStore(defaults: d).regexPresets.isEmpty)
        }
    }
```
- [ ] Implement: `@Published public var regexPresets: [RegexPreset] { didSet { writeJSON(… Key.regexPresets) } }`; init from `readJSON([RegexPreset].self, …) ?? []`; `addPreset` appends; `updatePreset` replaces by id (no-op if absent); `removePreset(id:)`. Key `pastefix.regexPresets`. `import PastefixCore` already present.
- [ ] green; **Commit** `feat(appcore): regexPresets setting with add/update/remove`.

---

### Task 3: App — registry wiring, reload sink, Presets tab

**Files:** Modify `Pastefix/Pastefix/AppModel.swift`, `PastefixApp.swift`, `SettingsView.swift`; Create `Pastefix/Pastefix/PresetsSettingsView.swift`.

- [ ] `AppModel.reload()`: `RegistryConfig(scriptsDirectory:…, wrapWidth:…, presets: settings.regexPresets)`.
- [ ] Delegate: `settings.$regexPresets.dropFirst().removeDuplicates().debounce(for: .milliseconds(200), scheduler: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.model.reload() } }`.
- [ ] `PresetsSettingsView.swift`:
```swift
struct PresetsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selected: UUID?
    @State private var draft: RegexPreset?
    @State private var sample = "The quick brown fox\njumps over the lazy dog"
    @State private var preview: String = ""
    @State private var previewInfo: String = ""      // "3 matches" / error
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(settings.regexPresets, selection: $selected) { p in Text(p.name.isEmpty ? "Untitled" : p.name).tag(p.id) }
                HStack {
                    Button { let p = RegexPreset(name: "New preset", pattern: "", replacement: ""); settings.addPreset(p); selected = p.id } label: { Image(systemName: "plus") }
                    Button { if let id = selected { settings.removePreset(id: id); selected = nil; draft = nil } } label: { Image(systemName: "minus") }.disabled(selected == nil)
                    Spacer()
                }.padding(6)
            }.frame(width: 160)
            Divider()
            if let d = Binding($draft) { editor(d) } else { Text("Select or add a preset").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onChange(of: selected) { _, id in draft = settings.regexPresets.first { $0.id == id }; schedulePreview() }
        .onChange(of: draft) { _, _ in schedulePreview() }
        .onChange(of: sample) { _, _ in schedulePreview() }
    }

    private func editor(_ d: Binding<RegexPreset>) -> some View {
        Form {
            TextField("Name", text: d.name)
            TextField("Pattern", text: d.pattern).font(.system(.body, design: .monospaced))
            if let err = compileError(d.wrappedValue) { Text(err).font(.caption).foregroundStyle(.red) }
            TextField("Replacement ($1, \\n, \\t)", text: d.replacement).font(.system(.body, design: .monospaced))
            Toggle("Case-insensitive", isOn: d.caseInsensitive)
            Toggle("^ and $ match at line boundaries", isOn: d.anchorsMatchLines)
            Toggle(". matches newlines", isOn: d.dotMatchesNewlines)
            Toggle("Replace all matches", isOn: d.replaceAll)
            Section("Preview") {
                TextEditor(text: $sample).font(.system(.caption, design: .monospaced)).frame(height: 60)
                Text(previewInfo).font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(preview).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 60)
            }
            HStack {
                Spacer()
                Button("Revert") { draft = settings.regexPresets.first { $0.id == d.wrappedValue.id } }
                Button("Save") { settings.updatePreset(d.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(compileError(d.wrappedValue) != nil || d.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.formStyle(.grouped)
    }

    private func compileError(_ p: RegexPreset) -> String? {
        do { _ = try p.compile(); return nil } catch let e as TransformError { if case .invalidInput(let m) = e { return m }; return "Invalid pattern" } catch { return "Invalid pattern" }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let p = draft else { preview = ""; previewInfo = ""; return }
        let text = String(sample.prefix(16_384))
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200)); guard !Task.isCancelled else { return }
            let result = await Task.detached { () -> Result<(String, Int), TransformError> in
                do {
                    let regex = try p.compile()
                    let count = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                    let out = try RegexPresetTransformer.replace(text, preset: p, deadline: .now + .seconds(1))
                    return .success((out, count))
                } catch let e as TransformError { return .failure(e) } catch { return .failure(.invalidInput("Invalid pattern")) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let (out, n)): preview = out; previewInfo = n == 1 ? "1 match" : "\(n) matches"
            case .failure(.timeout): preview = ""; previewInfo = "Pattern took too long on the sample (over 1 s)"
            case .failure(let e): preview = ""; previewInfo = TransformCoordinator.message(for: e)   // if not accessible, describe locally
            }
        }
    }
}
```
  (Adjust to the file's conventions; `TransformCoordinator.message(for:)` is internal to AppCore — if inaccessible, format the `invalidInput` message directly.)
- [ ] `SettingsView`: add `PresetsSettingsView(settings: settings).tabItem { Label("Presets", systemImage: "text.badge.plus") }` after Transforms. Note the Transforms tab lists presets automatically once the registry emits them.
- [ ] Build (`xcodebuild … | grep -E "error:|warning:|BUILD"` → BUILD SUCCEEDED, no new warnings); `swift test` unchanged. **Commit** `feat(app): Presets settings tab with live preview; registry reload on preset changes`.

---

### Task 4: Docs

- [ ] README: "Regex presets" section (where, fields, template syntax `$1` and `\n`/`\t`/`\\`, flags, limits 256 KB / 3 s, they appear in ⌘K/sidebar under Presets and can be enabled/reordered in Transforms). AGENTS: layout entries; Invariant 8 orders gain `900 (presets)`; Patterns bullet "user regexes run detached under the 3 s timeout with a 256 KB cap; the preview enforces 16 KB / 1 s"; status row Plan 12 (🟡). Banner. **Commit** `docs: regex presets — README, AGENTS`.

---

### Task 5: GUI pass (controller, ask first) and finish

- [ ] Settings → Presets → + → set pattern `(\w+)@(\w+)` replacement `$2 at $1` → preview updates → Save → ⌘⇧C on `bob@example` → ⌘K "New preset"/name → applied; sidebar shows Presets group before Scripts; invalid pattern `(` disables Save with the error. Restore the clipboard.
- [ ] Final review, one fix wave, AGENTS "bitten us", PR closing #12, `git checkout main`.

## Self-review
- Coverage: model/transformer/registry (T1); persistence (T2); wiring + tab (T3); docs (T4); pass (T5).
- Names: `RegexPreset(...)`, `.compile()`, `RegexPreset.expandEscapes`, `RegexPresetTransformer(preset:)`, `.maxBytes`, `.timeout`, `RegexPresetTransformer.replace(_:preset:deadline:)`, `RegistryConfig.presets`, `TransformerSource.preset`, `TransformCategory.presets`, `SettingsStore.regexPresets/addPreset/updatePreset/removePreset(id:)`.
