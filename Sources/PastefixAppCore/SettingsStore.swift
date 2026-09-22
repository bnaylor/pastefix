import Foundation
import Combine
import PastefixCore

/// UserDefaults-backed application settings. Published for SwiftUI binding;
/// each property writes through to `defaults` on mutation.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var wrapWidth: Int { didSet { defaults.set(wrapWidth, forKey: Key.wrapWidth) } }
    @Published public var autoHideOnBlur: Bool { didSet { defaults.set(autoHideOnBlur, forKey: Key.autoHide) } }
    @Published public var showSidebar: Bool { didSet { defaults.set(showSidebar, forKey: Key.showSidebar) } }
    @Published public var scriptsDirectoryPath: String { didSet { defaults.set(scriptsDirectoryPath, forKey: Key.scriptsDir) } }
    @Published public var transformEnabled: [String: Bool] { didSet { Self.writeJSON(transformEnabled, to: defaults, key: Key.enabled) } }
    @Published public var transformOrder: [String: Int] { didSet { Self.writeJSON(transformOrder, to: defaults, key: Key.order) } }
    @Published public var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) } }
    @Published public var historyMaxItems: Int {
        didSet {
            let clamped = min(max(historyMaxItems, 20), 1000)
            if clamped != historyMaxItems { historyMaxItems = clamped; return }
            defaults.set(historyMaxItems, forKey: Key.historyMaxItems)
        }
    }
    @Published public var historyExcludedBundleIDs: [String] { didSet { Self.writeJSON(historyExcludedBundleIDs, to: defaults, key: Key.historyExcluded) } }
    @Published public var regexPresets: [RegexPreset] { didSet { Self.writeJSON(regexPresets, to: defaults, key: Key.regexPresets) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wrapWidth = (defaults.object(forKey: Key.wrapWidth) as? Int) ?? 400
        self.autoHideOnBlur = (defaults.object(forKey: Key.autoHide) as? Bool) ?? true
        self.showSidebar = (defaults.object(forKey: Key.showSidebar) as? Bool) ?? false
        self.scriptsDirectoryPath = (defaults.string(forKey: Key.scriptsDir)) ?? Self.defaultScriptsPath
        self.transformEnabled = Self.readJSON([String: Bool].self, from: defaults, key: Key.enabled) ?? [:]
        self.transformOrder = Self.readJSON([String: Int].self, from: defaults, key: Key.order) ?? [:]
        self.historyEnabled = (defaults.object(forKey: Key.historyEnabled) as? Bool) ?? true
        self.historyMaxItems = min(max((defaults.object(forKey: Key.historyMaxItems) as? Int) ?? 200, 20), 1000)
        // Deliberately the whole-array decode, not `readLossyArray`: a `[String]` whose elements
        // are all malformed would decode element-wise to `[]`, i.e. an *empty* exclusion list —
        // fail-open for a privacy feature — where falling back to the seeds is fail-safe.
        self.historyExcludedBundleIDs = Self.readJSON([String].self, from: defaults, key: Key.historyExcluded) ?? ExclusionSeeds.passwordManagers
        self.regexPresets = Self.readLossyArray(RegexPreset.self, from: defaults, key: Key.regexPresets) ?? []
    }

    public var scriptsDirectoryURL: URL {
        URL(fileURLWithPath: scriptsDirectoryPath, isDirectory: true)
    }

    /// Reset the scripts directory back to the built-in default (~/.config/pastefix/scripts).
    public func resetScriptsDirectoryToDefault() {
        scriptsDirectoryPath = Self.defaultScriptsPath
    }

    public func addExcludedBundleID(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !historyExcludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
        historyExcludedBundleIDs.append(id)
    }
    public func removeExcludedBundleID(_ id: String) {
        historyExcludedBundleIDs.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
    public func restoreDefaultExclusions() { historyExcludedBundleIDs = ExclusionSeeds.passwordManagers }

    /// Names are trimmed here rather than in the editor so every writer gets it: a name of
    /// spaces passes an `isEmpty` check, sorts ahead of everything else in the 900 band, and
    /// shows as a blank row in the palette.
    public func addPreset(_ preset: RegexPreset) {
        regexPresets.append(Self.trimmingName(preset))
    }
    public func updatePreset(_ preset: RegexPreset) {
        guard let index = regexPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        regexPresets[index] = Self.trimmingName(preset)
    }
    /// Removing a preset also drops its enable/order overrides. They are keyed by the
    /// transformer id, which no longer exists, so leaving them behind means a restored presets
    /// backup comes back with a stale "disabled" from a preset the user deleted months ago.
    public func removePreset(id: UUID) {
        regexPresets.removeAll { $0.id == id }
        let transformerID = RegexPresetTransformer.transformerID(for: id)
        transformEnabled.removeValue(forKey: transformerID)
        transformOrder.removeValue(forKey: transformerID)
    }

    private static func trimmingName(_ preset: RegexPreset) -> RegexPreset {
        var trimmed = preset
        trimmed.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    static let defaultScriptsPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pastefix/scripts", isDirectory: true).path
    }()

    private enum Key {
        static let wrapWidth = "pastefix.wrapWidth"
        static let autoHide = "pastefix.autoHideOnBlur"
        static let showSidebar = "pastefix.showSidebar"
        static let scriptsDir = "pastefix.scriptsDirectoryPath"
        static let enabled = "pastefix.transformEnabled"
        static let order = "pastefix.transformOrder"
        static let historyEnabled = "pastefix.historyEnabled"
        static let historyMaxItems = "pastefix.historyMaxItems"
        static let historyExcluded = "pastefix.historyExcludedBundleIDs"
        static let regexPresets = "pastefix.regexPresets"
    }

    private static func writeJSON<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            assertionFailure("SettingsStore: failed to encode \(key): \(error)")
        }
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Reads a JSON array **element by element**, keeping the elements that decode.
    ///
    /// `readJSON([T].self, …)` is one `try?` over the whole array, so a single malformed element
    /// — a flag written as a string by a hand edit, a field a future build types differently —
    /// yields `nil`, the caller substitutes `[]`, and the next `didSet` writes that empty array
    /// back over the file. One bad preset out of twenty silently deleted the other nineteen.
    ///
    /// Returns `nil` only when the key is absent or the payload is not an array at all, so the
    /// caller's default still applies. (A non-array payload stays on disk until the user's next
    /// mutation: nothing here can repair a file it can't read.)
    private static func readLossyArray<Element: Decodable>(_ type: Element.Type, from defaults: UserDefaults,
                                                           key: String) -> [Element]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LossyArray<Element>.self, from: data).elements
    }

    /// An array that drops the elements it can't decode.
    ///
    /// The per-element `try?` lives in `LossyElement`, whose `init(from:)` never throws, because
    /// a `try?` around `container.decode` is not guaranteed to advance the unkeyed container's
    /// cursor past the element that failed — that shape can loop forever. A decode that always
    /// succeeds always advances.
    private struct LossyArray<Element: Decodable>: Decodable {
        let elements: [Element]

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var elements: [Element] = []
            if let count = container.count { elements.reserveCapacity(count) }
            while !container.isAtEnd {
                if let element = try container.decode(LossyElement<Element>.self).value {
                    elements.append(element)
                }
            }
            self.elements = elements
        }
    }

    private struct LossyElement<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: any Decoder) throws { value = try? Wrapped(from: decoder) }
    }
}
