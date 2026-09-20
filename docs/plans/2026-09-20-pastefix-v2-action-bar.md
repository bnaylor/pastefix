# Pastefix v2 Action Bar Revamp: ⌘K Palette + Sidebar (Plan 4) — Implementation Plan

> ## ⬜ STATUS: NOT STARTED — written 2026-09-20 from the approved spec (issue #7).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; SwiftUI (Tasks 5) → `swiftui-pro`. **TDD is required** for every engine and model task. The app target has no unit tests by design; Task 5 is verified by build + the human checklist in Task 6.

**Goal:** Replace the horizontally scrolling palette with a ⌘K command palette and an optional, persisted, category-grouped sidebar, backed by pure ranking/grouping code in `PastefixAppCore` and a `category` on every transform.

**Architecture:** `PastefixCore` gains `Transformer.category` (default nil), fixed categories on the built-ins, and a `category` script header. `PastefixAppCore` gains `TransformSearch` (ranked, highlighted results), `SidebarGrouping` (ordered sections), and `SettingsStore.showSidebar`. The Xcode target restructures `PanelView` (action bar, sidebar column, overlay host, Esc arbitration) and adds `SidebarView` and `CommandPaletteView`. No change to `AppModel`'s apply path or to Settings.

**Tech Stack:** Swift 6 SwiftPM packages + Swift Testing; SwiftUI (`@FocusState`, `onKeyPress` — macOS 14 floor), `AttributedString` highlighting, `UserDefaults` via `SettingsStore`.

**Spec:** `docs/specs/2026-09-20-pastefix-v2-action-bar.md` — read it first.

## Global Constraints

- **Packages stay dependency-free.** Nothing under `Sources/` imports anything beyond Foundation/Combine and `PastefixCore`.
- **Categories:** Layout = Wrap & Reflow, Whitespace Cleanup; Characters = Rich → Plain Text, Transliterate to ASCII; URLs = Clean URL Tracking, URL → Markdown Link; Case = the four `CaseConvert` styles. Scripts: `# pastefix: category = …` (trimmed; empty → nil), else nil → displayed under "Scripts". Display order: Layout, Characters, URLs, Case, then custom categories alphabetically, then Scripts. Empty sections omitted.
- **Search ranking:** tier 1 folded-name prefix; tier 2 any word start (words split on space, `_`, `-`, `→`, `&`, `/`); tier 3 in-order subsequence; else excluded. Within a tier: applicable-to-detected first, then input order. Folding = case- and diacritic-insensitive. Empty/whitespace query → `PaletteOrdering.order(transformers, for: kinds)`, tier 0, no ranges. Highlight ranges are valid indices into the original `name` (tiers 1–2 one contiguous range; tier 3 one range per matched character, adjacent ones merged).
- **Sidebar setting:** `SettingsStore.showSidebar`, key `pastefix.showSidebar`, default `false`.
- **Keys:** ⌘K toggles the palette; ↑/↓ move selection with wraparound; ↵ applies the selection (default first); Esc closes the palette; a click on the backdrop closes it. Cancel's `.cancelAction` shortcut is attached only while the palette is closed. ⌘⇧L toggles the sidebar. Palette and sidebar are disabled while `model.isApplying`.
- **Layout:** the horizontal palette is removed. Action bar at the bottom holds the "Transform… ⌘K" button, the Detected badge, and the spinner. Sidebar column is 220 pt; the panel's minimum width is 560 without it and 780 with it. Palette card ≈ 520 pt wide, up to 8 visible rows.
- **No Settings window changes. No `AppModel` API changes** beyond reading `enabledTransformers()` and `document?.detectedKinds`.
- **Branch:** `feat/action-bar` in this checkout (no worktree). Conventional commits with `Co-Authored-By: Claude <noreply@anthropic.com>`. PR closes #7.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/PastefixCore/Transformer.swift` | `category` requirement + default; `TransformCategory` constants |
| `Sources/PastefixCore/Native/*.swift` (8 files) | `public let category: String? = …` |
| `Sources/PastefixCore/Scripting/ScriptMetadata.swift`, `ShellTransformer.swift`, `JSTransformer.swift` | `category` header → `category` |
| `Sources/PastefixAppCore/SettingsStore.swift` | `showSidebar` |
| `Sources/PastefixAppCore/SidebarGrouping.swift` (new) | `sections(_:)` |
| `Sources/PastefixAppCore/TransformSearch.swift` (new) | `rank(query:in:kinds:)`, `SearchResult` |
| `Pastefix/Pastefix/PanelView.swift` | action bar, sidebar column, overlay host, Esc arbitration, `settings` param |
| `Pastefix/Pastefix/SidebarView.swift` (new) | grouped `List` |
| `Pastefix/Pastefix/CommandPaletteView.swift` (new) | ⌘K overlay |
| `Pastefix/Pastefix/PastefixApp.swift` | pass `settings` to `PanelView` |
| Tests: `ScriptMetadataTests`, `TransformerRegistryTests`, the 5 native `metadata()` tests (extend); `SettingsStoreTests` (extend); `SidebarGroupingTests`, `TransformSearchTests` (new) | |
| `README.md`, `AGENTS.md` | currency |

---

### Task 0: Branch

- [ ] `git checkout main && git pull --ff-only && git checkout -b feat/action-bar && swift test 2>&1 | tail -1` → `170 tests in 23 suites passed`.

---

### Task 1: `category` on transformers and scripts

**Files:**
- Modify: `Sources/PastefixCore/Transformer.swift`
- Modify: `Sources/PastefixCore/Native/{RichToPlain,Transliterate,WrapReflow,WhitespaceCleanup,URLCleaner,MarkdownLink,CaseConvert}.swift`
- Modify: `Sources/PastefixCore/Scripting/{ScriptMetadata,ShellTransformer,JSTransformer}.swift`
- Test: `Tests/PastefixCoreTests/ScriptMetadataTests.swift`, `TransformerRegistryTests.swift`, and the `metadata()` tests in `RichToPlainTests`, `WhitespaceCleanupTests`, `MarkdownLinkTests`, `CaseConvertTests`, `URLCleanerTests` (`applyAndMetadata`)

**Interfaces:**
- Produces: `Transformer.category: String?` (default nil); `public enum TransformCategory { static let layout = "Layout", characters = "Characters", urls = "URLs", case = "Case", scripts = "Scripts"; static let builtinOrder: [String] }`; `ScriptMetadata.category: String?`.

- [ ] **Step 1: Failing tests.** Append to `ScriptMetadataTests`:

```swift
    @Test func parsesCategory() {
        #expect(ScriptMetadata.parse("# pastefix: category = Text").category == "Text")
        #expect(ScriptMetadata.parse("# pastefix: category =   Spaced Out  ").category == "Spaced Out")
        #expect(ScriptMetadata.parse("# pastefix: category =").category == nil)
        #expect(ScriptMetadata.parse("# pastefix: name = X").category == nil)
    }
```

Append to `TransformerRegistryTests`:

```swift
    @Test func builtinsCarryTheirCategories() throws {
        let dir = try makeTempDir()
        let byID = Dictionary(uniqueKeysWithValues: TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load().map { ($0.id, $0.category) })
        #expect(byID["builtin.wrapreflow"] == TransformCategory.layout)
        #expect(byID["builtin.whitespace"] == TransformCategory.layout)
        #expect(byID["builtin.richtoplain"] == TransformCategory.characters)
        #expect(byID["builtin.transliterate"] == TransformCategory.characters)
        #expect(byID["builtin.urlclean"] == TransformCategory.urls)
        #expect(byID["builtin.markdownlink"] == TransformCategory.urls)
        for style in ["camel", "snake", "kebab", "constant"] { #expect(byID["builtin.case.\(style)"] == TransformCategory.case) }
        #expect(TransformCategory.builtinOrder == ["Layout", "Characters", "URLs", "Case"])
    }

    @Test func scriptCategorySurfaces() throws {
        let dir = try makeTempDir()
        try "#!/bin/sh\n# pastefix: name = Cat\n# pastefix: category = Text\ncat".write(to: dir.appendingPathComponent("cat.sh"), atomically: true, encoding: .utf8)
        try "// pastefix: name = NoCat\nfunction transform(t){return t;}".write(to: dir.appendingPathComponent("nocat.js"), atomically: true, encoding: .utf8)
        let loaded = TransformerRegistry(config: .init(scriptsDirectory: dir, wrapWidth: 80)).load()
        #expect(loaded.first { $0.name == "Cat" }?.category == "Text")
        #expect(loaded.first { $0.name == "NoCat" }?.category == nil)
    }
```

In each native `metadata()` test add one assertion, e.g. `#expect(subject.category == TransformCategory.layout)` for WhitespaceCleanup, `.characters` for RichToPlain, `.urls` for URLCleaner and MarkdownLink, `.case` inside CaseConvert's loop. Add `metadata()` tests for `Transliterate` and `WrapReflow` if none exist (id, source, category).

- [ ] **Step 2:** `swift test --filter "ScriptMetadataTests|TransformerRegistryTests"` → compile errors (`category` unknown).

- [ ] **Step 3: Implement.** In `Transformer.swift` add to the protocol after `applicableKinds`:

```swift
    /// Display group for browsing UIs (sidebar sections, palette subtitles). `nil` means
    /// uncategorised; scripts without a `category` header are shown under "Scripts".
    var category: String? { get }
```

extend the default extension with `var category: String? { nil }`, and add:

```swift
/// Category names shared by the built-ins, the grouping code, and tests.
public enum TransformCategory {
    public static let layout = "Layout"
    public static let characters = "Characters"
    public static let urls = "URLs"
    public static let `case` = "Case"
    public static let scripts = "Scripts"
    /// Display order for the built-in categories; custom ones follow alphabetically, then Scripts.
    public static let builtinOrder = [layout, characters, urls, `case`]
}
```

Add `public let category: String? = TransformCategory.<x>` to each native transform next to `source` (CaseConvert: `= TransformCategory.case`, one line for all styles). `ScriptMetadata`: add `public var category: String?`, init param `category: String? = nil`, and

```swift
            case "category":
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                md.category = trimmed.isEmpty ? nil : trimmed
```

`ShellTransformer`/`JSTransformer`: `public let category: String?` assigned from `metadata.category`.

- [ ] **Step 4:** `swift test` (full) → green.
- [ ] **Step 5: Commit** `feat(core): transformers carry a display category; built-ins fixed, scripts via 'category' header`.

---

### Task 2: `SettingsStore.showSidebar`

**Files:** `Sources/PastefixAppCore/SettingsStore.swift`; `Tests/PastefixAppCoreTests/SettingsStoreTests.swift`.

- [ ] **Step 1: Failing test** (uses the file's `withFreshDefaults` helper):

```swift
    @Test func showSidebarDefaultsOffAndPersists() {
        withFreshDefaults { d in
            let s = SettingsStore(defaults: d)
            #expect(s.showSidebar == false)
            s.showSidebar = true
            #expect(SettingsStore(defaults: d).showSidebar == true)
        }
    }
```

- [ ] **Step 2:** `swift test --filter SettingsStoreTests` → compile error.
- [ ] **Step 3: Implement:** `@Published public var showSidebar: Bool { didSet { defaults.set(showSidebar, forKey: Key.showSidebar) } }`, init `self.showSidebar = (defaults.object(forKey: Key.showSidebar) as? Bool) ?? false`, `static let showSidebar = "pastefix.showSidebar"`.
- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(appcore): persist showSidebar in SettingsStore`.

---

### Task 3: `SidebarGrouping`

**Files:** Create `Sources/PastefixAppCore/SidebarGrouping.swift`; Test `Tests/PastefixAppCoreTests/SidebarGroupingTests.swift`.

**Interfaces:** `public struct SidebarSection: Identifiable, Sendable { public let title: String; public var id: String { title }; public let transformers: [any Transformer] }`; `public enum SidebarGrouping { public static func sections(_ transformers: [any Transformer]) -> [SidebarSection] }`.

- [ ] **Step 1: Failing tests**

```swift
import Testing
import PastefixCore
@testable import PastefixAppCore

private struct CatTransformer: Transformer {
    let id: String
    let category: String?
    var name: String { id }
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite struct SidebarGroupingTests {
    private func titles(_ list: [any Transformer]) -> [String] { SidebarGrouping.sections(list).map(\.title) }

    @Test func builtinOrderThenCustomAlphabeticalThenScripts() {
        let list: [any Transformer] = [
            CatTransformer(id: "s1", category: nil),
            CatTransformer(id: "z", category: "Zeta"),
            CatTransformer(id: "c1", category: TransformCategory.case),
            CatTransformer(id: "a", category: "Alpha"),
            CatTransformer(id: "l1", category: TransformCategory.layout),
            CatTransformer(id: "u1", category: TransformCategory.urls),
        ]
        #expect(titles(list) == ["Layout", "URLs", "Case", "Alpha", "Zeta", "Scripts"])
    }
    @Test func emptySectionsOmittedAndOrderWithinSectionPreserved() {
        let list: [any Transformer] = [
            CatTransformer(id: "l2", category: TransformCategory.layout),
            CatTransformer(id: "l1", category: TransformCategory.layout),
        ]
        let s = SidebarGrouping.sections(list)
        #expect(s.count == 1)
        #expect(s[0].transformers.map(\.id) == ["l2", "l1"])
    }
    @Test func scriptsExplicitCategoryEqualToScriptsLandsLast() {
        let list: [any Transformer] = [CatTransformer(id: "x", category: "Scripts"), CatTransformer(id: "b", category: "Beta")]
        #expect(titles(list) == ["Beta", "Scripts"])
    }
    @Test func emptyInput() { #expect(SidebarGrouping.sections([]).isEmpty) }
}
```

- [ ] **Step 2:** `swift test --filter SidebarGroupingTests` → compile error.
- [ ] **Step 3: Implement**

```swift
import Foundation
import PastefixCore

public struct SidebarSection: Identifiable, Sendable {
    public let title: String
    public var id: String { title }
    public let transformers: [any Transformer]
}

/// Groups transforms for the sidebar: built-in categories in their fixed order, then any
/// custom categories alphabetically, then "Scripts" (the bucket for transforms with no
/// category). Order within a section is the incoming (user) order.
public enum SidebarGrouping {
    public static func sections(_ transformers: [any Transformer]) -> [SidebarSection] {
        var buckets: [String: [any Transformer]] = [:]
        for t in transformers {
            buckets[t.category ?? TransformCategory.scripts, default: []].append(t)
        }
        let builtin = TransformCategory.builtinOrder.filter { buckets[$0] != nil }
        let custom = buckets.keys
            .filter { !TransformCategory.builtinOrder.contains($0) && $0 != TransformCategory.scripts }
            .sorted()
        let tail = buckets[TransformCategory.scripts] == nil ? [] : [TransformCategory.scripts]
        return (builtin + custom + tail).map { SidebarSection(title: $0, transformers: buckets[$0] ?? []) }
    }
}
```

- [ ] **Step 4:** filter green; full suite green.
- [ ] **Step 5: Commit** `feat(appcore): SidebarGrouping orders transform sections by category`.

---

### Task 4: `TransformSearch`

**Files:** Create `Sources/PastefixAppCore/TransformSearch.swift`; Test `Tests/PastefixAppCoreTests/TransformSearchTests.swift`.

**Interfaces:**
```swift
public struct SearchResult: Identifiable, Sendable {
    public let transformer: any Transformer
    public var id: String { transformer.id }
    public let matchedRanges: [Range<String.Index>]   // into transformer.name
    public let tier: Int                                // 0 none, 1 prefix, 2 word start, 3 subsequence
}
public enum TransformSearch {
    public static func rank(query: String, in transformers: [any Transformer], kinds: Set<ContentKind>) -> [SearchResult]
}
```

- [ ] **Step 1: Failing tests**

```swift
import Testing
import PastefixCore
@testable import PastefixAppCore

private struct T: Transformer {
    let id: String
    let name: String
    var applicableKinds: Set<ContentKind>? = nil
    let requiresRichInput = false
    let source: TransformerSource = .builtin
    func apply(_ input: TransformInput) async throws -> String { input.text }
}

@Suite struct TransformSearchTests {
    let list: [any Transformer] = [
        T(id: "wrap", name: "Wrap & Reflow"),
        T(id: "ws", name: "Whitespace Cleanup"),
        T(id: "clean", name: "Clean URL Tracking", applicableKinds: [.url]),
        T(id: "md", name: "URL → Markdown Link", applicableKinds: [.url]),
        T(id: "camel", name: "camelCase"),
        T(id: "cafe", name: "Café Filter"),
    ]
    private func ids(_ q: String, kinds: Set<ContentKind> = []) -> [String] { TransformSearch.rank(query: q, in: list, kinds: kinds).map(\.id) }
    private func highlighted(_ q: String, _ id: String) -> [String] {
        let r = TransformSearch.rank(query: q, in: list, kinds: []).first { $0.id == id }!
        return r.matchedRanges.map { String(r.transformer.name[$0]) }
    }

    @Test func emptyQueryIsPaletteOrder() {
        let r = TransformSearch.rank(query: "   ", in: list, kinds: [.url])
        #expect(r.map(\.id) == ["clean", "md", "wrap", "ws", "camel", "cafe"])
        #expect(r.allSatisfy { $0.tier == 0 && $0.matchedRanges.isEmpty })
    }
    @Test func prefixBeatsWordStartBeatsSubsequence() {
        // "url": prefix of "URL → Markdown Link"; word start in "Clean URL Tracking"; subsequence nowhere else.
        #expect(ids("url") == ["md", "clean"])
        let tiers = TransformSearch.rank(query: "url", in: list, kinds: []).map(\.tier)
        #expect(tiers == [1, 2])
    }
    @Test func subsequenceMatchesAndHighlightsEachCharacter() {
        #expect(ids("cut").contains("clean"))
        #expect(highlighted("cut", "clean") == ["C", "U", "T"])   // C(lean) U(RL) T(racking)
    }
    @Test func contiguousHighlightForPrefixAndWordStart() {
        #expect(highlighted("url", "md") == ["URL"])
        #expect(highlighted("url", "clean") == ["URL"])
    }
    @Test func caseAndDiacriticInsensitive() {
        #expect(ids("CLEAN") == ["clean", "ws"])   // prefix, then "Cleanup" word start
        #expect(ids("cafe") == ["cafe"])
        #expect(highlighted("cafe", "cafe") == ["Café"])
    }
    @Test func nonMatchExcluded() { #expect(ids("zzz").isEmpty) }
    @Test func applicableFirstWithinTier() {
        // "c" is a prefix of camelCase, Clean URL Tracking, Café Filter; only Clean is applicable to url.
        #expect(ids("c", kinds: [.url]) == ["clean", "camel", "cafe"])
        #expect(ids("c") == ["clean", "camel", "cafe"])   // no kinds: input order among prefix matches
    }
    @Test func rangesAreValidIndicesOfOriginalName() {
        for r in TransformSearch.rank(query: "a", in: list, kinds: []) {
            for range in r.matchedRanges {
                #expect(range.lowerBound >= r.transformer.name.startIndex && range.upperBound <= r.transformer.name.endIndex)
            }
        }
    }
}
```

- [ ] **Step 2:** `swift test --filter TransformSearchTests` → compile error.
- [ ] **Step 3: Implement**

```swift
import Foundation
import PastefixCore

public struct SearchResult: Identifiable, Sendable {
    public let transformer: any Transformer
    public var id: String { transformer.id }
    /// Ranges into `transformer.name` to highlight. Empty for an empty query.
    public let matchedRanges: [Range<String.Index>]
    /// 0 = no query (palette order), 1 = prefix, 2 = word start, 3 = subsequence.
    public let tier: Int
}

/// Ranks transforms for the ⌘K palette. Pure; the view only renders the result.
public enum TransformSearch {
    public static func rank(query: String, in transformers: [any Transformer], kinds: Set<ContentKind>) -> [SearchResult] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else {
            return PaletteOrdering.order(transformers, for: kinds).map { SearchResult(transformer: $0, matchedRanges: [], tier: 0) }
        }
        let qChars = Array(q)
        var hits: [(result: SearchResult, applicable: Bool, index: Int)] = []
        for (index, t) in transformers.enumerated() {
            guard let (tier, ranges) = match(qChars, in: t.name) else { continue }
            let applicable = t.applicableKinds.map { !$0.isDisjoint(with: kinds) } ?? false
            hits.append((SearchResult(transformer: t, matchedRanges: ranges, tier: tier), applicable, index))
        }
        return hits.sorted { a, b in
            if a.result.tier != b.result.tier { return a.result.tier < b.result.tier }
            if a.applicable != b.applicable { return a.applicable }
            return a.index < b.index
        }.map(\.result)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static let wordSeparators: Set<Character> = [" ", "_", "-", "→", "&", "/"]

    /// Matches per character so highlight ranges map 1:1 onto the original name: each
    /// character of `name` is folded on its own and compared by its first scalar.
    static func match(_ q: [Character], in name: String) -> (tier: Int, ranges: [Range<String.Index>])? {
        let chars = Array(name)
        let folded: [Character] = chars.map { fold(String($0)).first ?? $0 }
        let indices = Array(name.indices) + [name.endIndex]
        func range(_ from: Int, _ to: Int) -> Range<String.Index> { indices[from]..<indices[to] }
        func hasPrefix(at start: Int) -> Bool {
            guard start + q.count <= folded.count else { return false }
            return Array(folded[start..<start + q.count]) == q
        }
        if hasPrefix(at: 0) { return (1, [range(0, q.count)]) }
        for i in 1..<max(1, chars.count) where wordSeparators.contains(chars[i - 1]) && !wordSeparators.contains(chars[i]) {
            if hasPrefix(at: i) { return (2, [range(i, i + q.count)]) }
        }
        var matched: [Int] = []
        var qi = 0
        for (ci, c) in folded.enumerated() where qi < q.count && c == q[qi] {
            matched.append(ci); qi += 1
        }
        guard qi == q.count else { return nil }
        var ranges: [Range<String.Index>] = []
        var runStart = matched[0], prev = matched[0]
        for m in matched.dropFirst() {
            if m == prev + 1 { prev = m; continue }
            ranges.append(range(runStart, prev + 1)); runStart = m; prev = m
        }
        ranges.append(range(runStart, prev + 1))
        return (3, ranges)
    }
}
```

- [ ] **Step 4:** filter green; full suite green. If `caseAndDiacriticInsensitive` fails on `"CLEAN"` ordering, check that the word-start scan treats the `" "` before "Cleanup" as a separator (it should); do not weaken the test.
- [ ] **Step 5: Commit** `feat(appcore): TransformSearch ranks and highlights palette matches`.

---

### Task 5: Panel UI — action bar, sidebar, ⌘K palette

**Files:**
- Modify: `Pastefix/Pastefix/PanelView.swift` (full rewrite of the layout; keep toolbar semantics)
- Create: `Pastefix/Pastefix/SidebarView.swift`, `Pastefix/Pastefix/CommandPaletteView.swift`
- Modify: `Pastefix/Pastefix/PastefixApp.swift:60` → `PanelView(model: model, settings: settings)`

**Interfaces:** Consumes `TransformSearch.rank`, `SidebarGrouping.sections`, `SettingsStore.showSidebar`, `AppModel.enabledTransformers()`, `AppModel.detectedSummary`, `AppModel.apply`.

- [ ] **Step 1: `CommandPaletteView.swift`**

```swift
import SwiftUI
import PastefixCore
import PastefixAppCore

/// ⌘K overlay: type to filter, ↑↓ to choose, ↵ to apply, Esc to close.
struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var results: [SearchResult] {
        TransformSearch.rank(query: query, in: model.enabledTransformers(), kinds: model.document?.detectedKinds ?? [])
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            card
                .frame(width: 520)
                .padding(.top, 40)
        }
        .onAppear { fieldFocused = true }
    }

    private var card: some View {
        let items = results
        let selected = items.isEmpty ? 0 : min(selection, items.count - 1)
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Transform…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { apply(items, selected) }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                Text("No matching transforms").foregroundStyle(.secondary).padding(16)
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, result in
                        row(result, isSelected: index == selected)
                            .contentShape(Rectangle())
                            .onTapGesture { apply(items, index) }
                            .listRowBackground(index == selected ? Color.accentColor.opacity(0.25) : Color.clear)
                            .id(result.id)
                    }
                    .listStyle(.plain)
                    .frame(height: CGFloat(min(items.count, 8)) * 44)
                    .onChange(of: selected) { _, new in proxy.scrollTo(items[new].id) }
                }
            }
            Divider()
            HStack(spacing: 16) {
                Label("Apply", systemImage: "return")
                Label("Choose", systemImage: "arrow.up.arrow.down")
                Text("esc Close")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
        .onKeyPress(.downArrow) { move(+1, count: items.count); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ result: SearchResult, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedName(result))
                if let category = result.transformer.category {
                    Text(category).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected { Image(systemName: "return").foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    private func highlightedName(_ result: SearchResult) -> AttributedString {
        var text = AttributedString(result.transformer.name)
        for range in result.matchedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = .body.bold()
            text[lower..<upper].foregroundColor = .accentColor
        }
        return text
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = ((selection + delta) % count + count) % count
    }

    private func apply(_ items: [SearchResult], _ index: Int) {
        guard items.indices.contains(index) else { return }
        let transformer = items[index].transformer
        onClose()
        model.apply(transformer)
    }
}
```

- [ ] **Step 2: `SidebarView.swift`**

```swift
import SwiftUI
import PastefixCore
import PastefixAppCore

/// Vertical, category-grouped list of enabled transforms. Click to apply.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ForEach(SidebarGrouping.sections(model.enabledTransformers())) { section in
                Section(section.title) {
                    ForEach(section.transformers, id: \.id) { transformer in
                        Button(transformer.name) { model.apply(transformer) }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 220)
        .disabled(model.isApplying)
    }
}
```

- [ ] **Step 3: `PanelView.swift`** — replace the body/toolbar/palette with:

```swift
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var isPaletteOpen = false
    @FocusState private var editorFocused: Bool

    private var workingBinding: Binding<String> { … unchanged … }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 0) {
                        TextEditor(text: workingBinding)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .disabled(model.isApplying)
                            .focused($editorFocused)
                        if let error = model.errorMessage { errorBanner(error) }
                    }
                    if isPaletteOpen {
                        CommandPaletteView(model: model, onClose: closePalette)
                            .transition(.opacity)
                    }
                }
                if settings.showSidebar {
                    Divider()
                    SidebarView(model: model)
                }
            }
            Divider()
            actionBar
        }
        .frame(minWidth: settings.showSidebar ? 780 : 560, minHeight: 380)
        .animation(.easeInOut(duration: 0.15), value: settings.showSidebar)
        .animation(.easeInOut(duration: 0.1), value: isPaletteOpen)
        // A new session always starts with the palette closed.
        .onChange(of: model.document == nil) { _, ended in if ended { isPaletteOpen = false } }
    }

    private var toolbar: some View {
        HStack {
            Button("Undo") { model.undo() }.disabled(model.isApplying || model.document?.canUndo != true)
            Button("Redo") { model.redo() }.disabled(model.isApplying || model.document?.canRedo != true)
            Button("Refresh") { model.refresh() }.disabled(model.isApplying)
            Spacer()
            Button { settings.showSidebar.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(settings.showSidebar ? "Hide Transforms Sidebar (⌘⇧L)" : "Show Transforms Sidebar (⌘⇧L)")
                .keyboardShortcut("l", modifiers: [.command, .shift])
            // Cancel stays enabled during a slow transform. Its Esc binding is detached while
            // the palette is open so a first Esc closes the palette, not the panel.
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(isPaletteOpen ? nil : .cancelAction)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isApplying)
        }
        .padding(8)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { togglePalette() } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Transform…")
                    Spacer()
                    Text("⌘K").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.isApplying)
            .accessibilityLabel("Find a transform")
            if let summary = model.detectedSummary {
                Text("Detected: \(summary)").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Detected content: \(summary)")
            }
            if model.isApplying {
                ProgressView().controlSize(.small).accessibilityLabel("Applying transform")
            }
        }
        .padding(8)
    }

    private func togglePalette() { if isPaletteOpen { closePalette() } else { isPaletteOpen = true } }
    private func closePalette() { isPaletteOpen = false; editorFocused = true }

    private func errorBanner(_ text: String) -> some View { … unchanged … }
}
```

Delete the old `palette` property.

- [ ] **Step 4: `PastefixApp.swift`** line 60: `PanelView(model: model, settings: settings)`.

- [ ] **Step 5: Build**

```bash
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet 2>&1 | grep -v HotkeyName | grep -E "error|warning"; echo "exit ${pipestatus[1]}"
```

Expected: exit 0, no new warnings. Likely compile notes: `.keyboardShortcut(_:)` with an optional argument needs the `KeyboardShortcut?` overload (`.keyboardShortcut(isPaletteOpen ? nil : KeyboardShortcut.cancelAction)` if type inference struggles); `List(Array(items.enumerated()), id: \.element.id)` may need `ForEach` inside `List` instead; `AttributedString.Index(_:within:)` returns an optional — already guarded.

- [ ] **Step 6: Commit** `feat(app): ⌘K command palette, category sidebar, and action bar replace the horizontal palette`.

---

### Task 6: Manual verification (human, `Pastefix/launch.sh`)

- [ ] 1. Summon with `Read https://www.example.com/page?utm_source=x soon.` The old horizontal bar is gone; the action bar shows "Transform… ⌘K" and `Detected: URL`.
- [ ] 2. ⌘K → overlay opens, field focused, results list starts with the two URL transforms (applicable first). ↓ ↓ ↑ moves the highlight with wraparound; Esc closes only the overlay; the panel is still there.
- [ ] 3. ⌘K, type `url` → "URL → Markdown Link" (prefix) above "Clean URL Tracking" (word start), "URL" bold in both, category subtitles visible. ↵ applies the first; overlay closes; editor shows the link; spinner appeared briefly in the action bar.
- [ ] 4. ⌘K, type `zzz` → "No matching transforms"; ↵ does nothing; click the dimmed background → closes.
- [ ] 5. Esc with the palette closed → panel cancels (Esc's second meaning).
- [ ] 6. Summon again; toolbar sidebar button → column appears with LAYOUT / CHARACTERS / URLS / CASE sections in that order; window widened. Click "Whitespace Cleanup" → applies. ⌘⇧L hides it. Show it again, quit, relaunch, summon → still shown. Hide it.
- [ ] 7. Add `~/.config/pastefix/scripts/rot.sh` with `# pastefix: category = Text` → appears under TEXT between CASE and SCRIPTS; a script without a header appears under SCRIPTS. Remove the scripts.
- [ ] 8. During a slow apply (`https://httpbin.org/delay/10` → Markdown Link) ⌘K and sidebar clicks do nothing; Cancel still works.
- [ ] 9. Settings → Transforms: disable "kebab-case" → gone from both the palette results and the sidebar; re-enable.

Record results in the PR description.

---

### Task 7: Documentation

- [ ] **README:** under "The app", replace the palette paragraph with "**Finding transforms.** Press ⌘K (or click the Transform… bar) for a command palette: type to filter, ↑↓ to choose, ↵ to apply, Esc to close; transforms that apply to the detected content are listed first. Toggle the sidebar (⌘⇧L or the toolbar button) to browse all enabled transforms grouped by category; the sidebar state is remembered." In "Script Metadata" add `category` (free text; groups the script in the sidebar; default Scripts) and a table of the built-in categories.
- [ ] **AGENTS.md:** layout entries for `TransformSearch.swift`, `SidebarGrouping.swift`, `SidebarView.swift`, `CommandPaletteView.swift`; `PanelView.swift` comment → "editor + action bar + ⌘K overlay + sidebar host"; Patterns bullet: *browsing UIs (palette, sidebar) read `enabledTransformers()`; ranking, grouping, and searching are pure functions in AppCore*; a note under "Things that have bitten us" only if something bit during Task 6; status table row `| 4 — Action bar | ⌘K palette, sidebar, categories | 🟡 in review on \`feat/action-bar\`, PR pending |`.
- [ ] Commit `docs: document the ⌘K palette, sidebar, and transform categories`.

---

### Task 8: PR

- [ ] `swift test` green; Release build clean; tree clean.
- [ ] `git push -u origin feat/action-bar` and `gh pr create --base main --title "feat: ⌘K command palette and category sidebar (Plan 4)" --body …` with Summary / Verification (Task 6 results) / "Closes #7".
- [ ] After merge: flip this banner and the AGENTS.md row to ✅ with the merge SHA. No release unless asked.
