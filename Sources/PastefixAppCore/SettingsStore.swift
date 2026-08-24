import Foundation
import Combine

/// UserDefaults-backed application settings. Published for SwiftUI binding;
/// each property writes through to `defaults` on mutation.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var wrapWidth: Int { didSet { defaults.set(wrapWidth, forKey: Key.wrapWidth) } }
    @Published public var autoHideOnBlur: Bool { didSet { defaults.set(autoHideOnBlur, forKey: Key.autoHide) } }
    @Published public var scriptsDirectoryPath: String { didSet { defaults.set(scriptsDirectoryPath, forKey: Key.scriptsDir) } }
    @Published public var transformEnabled: [String: Bool] { didSet { Self.writeJSON(transformEnabled, to: defaults, key: Key.enabled) } }
    @Published public var transformOrder: [String: Int] { didSet { Self.writeJSON(transformOrder, to: defaults, key: Key.order) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wrapWidth = (defaults.object(forKey: Key.wrapWidth) as? Int) ?? 400
        self.autoHideOnBlur = (defaults.object(forKey: Key.autoHide) as? Bool) ?? true
        self.scriptsDirectoryPath = (defaults.string(forKey: Key.scriptsDir)) ?? Self.defaultScriptsPath
        self.transformEnabled = Self.readJSON([String: Bool].self, from: defaults, key: Key.enabled) ?? [:]
        self.transformOrder = Self.readJSON([String: Int].self, from: defaults, key: Key.order) ?? [:]
    }

    public var scriptsDirectoryURL: URL {
        URL(fileURLWithPath: scriptsDirectoryPath, isDirectory: true)
    }

    static let defaultScriptsPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pastefix/scripts", isDirectory: true).path
    }()

    private enum Key {
        static let wrapWidth = "pastefix.wrapWidth"
        static let autoHide = "pastefix.autoHideOnBlur"
        static let scriptsDir = "pastefix.scriptsDirectoryPath"
        static let enabled = "pastefix.transformEnabled"
        static let order = "pastefix.transformOrder"
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
