import Foundation

public struct RegistryConfig: Sendable {
    public var scriptsDirectory: URL
    public var wrapWidth: Int
    public var timeout: TimeInterval
    /// User-defined regex find & replace rules, surfaced as transforms at order band 900.
    public var presets: [RegexPreset]

    public init(scriptsDirectory: URL, wrapWidth: Int = 400, timeout: TimeInterval = 3,
                presets: [RegexPreset] = []) {
        self.scriptsDirectory = scriptsDirectory
        self.wrapWidth = wrapWidth
        self.timeout = timeout
        self.presets = presets
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
            (11, "Rich → Markdown", RichToMarkdown()),
            (12, "Markdown → Rich Text", MarkdownToRich()),
            (20, "Transliterate to ASCII", Transliterate()),
            (30, "Wrap & Reflow", WrapReflow(width: config.wrapWidth)),
            (40, "Whitespace Cleanup", WhitespaceCleanup()),
            (50, "Clean URL Tracking", URLCleaner()),
            (60, "URL → Markdown Link", MarkdownLink()),
            (70, "camelCase", CaseConvert(style: .camel)),
            (71, "snake_case", CaseConvert(style: .snake)),
            (72, "kebab-case", CaseConvert(style: .kebab)),
            (73, "CONSTANT_CASE", CaseConvert(style: .constant)),
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
            (110, "Redact Secrets", RedactSecrets()),
        ]

        // Presets sit after every built-in (band 900) and before discovered scripts (1000+).
        // No pre-sort: the single sort below orders the whole band.
        for p in config.presets {
            entries.append((900, p.name, RegexPresetTransformer(preset: p)))
        }

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

        // Sort once, with the comparator we actually mean: `String.<` is case-sensitive, so a
        // tuple sort would put every capitalised name ahead of every lowercase one within a band
        // (presets at 900, scripts at 1000 — both user-named, both visibly wrong that way).
        return entries
            .sorted {
                $0.order == $1.order
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.order < $1.order
            }
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
