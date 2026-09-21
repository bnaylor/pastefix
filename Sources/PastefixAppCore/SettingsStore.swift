import Foundation
import Combine

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
        self.historyExcludedBundleIDs = Self.readJSON([String].self, from: defaults, key: Key.historyExcluded) ?? ExclusionSeeds.passwordManagers
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
}
