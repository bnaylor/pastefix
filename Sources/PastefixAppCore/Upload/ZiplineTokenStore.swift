import Foundation
import Security

/// Where the Zipline API token lives. A protocol because the Keychain conformer cannot be
/// unit-tested without writing to a real login keychain.
public protocol ZiplineTokenStore: Sendable {
    func token() throws -> String?
    func setToken(_ token: String) throws
    func clearToken() throws
}

/// Carries only the raw status code — never the token itself, which must not be logged,
/// printed, or surfaced in an error message anywhere in this pipeline.
public enum TokenStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Generic-password item under a fixed service. The token is the one piece of Pastefix's
/// configuration that must not sit in `UserDefaults` JSON, which is readable by anything
/// running as this user.
public struct KeychainTokenStore: ZiplineTokenStore {
    public static let service = "net.scromp.Pastefix.zipline"
    private let account = "api-token"

    public init() {}

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func token() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        // A stored-but-empty value reads back as "no token", matching setToken's own rule that
        // an empty string means "remove" rather than "the token is empty".
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8),
              !string.isEmpty else { return nil }
        return string
    }

    public func setToken(_ token: String) throws {
        // Blanking the Settings field must remove the token, not store "" and let it sail past
        // a nil check to fail later as a confusing 401.
        guard !token.isEmpty else { return try clearToken() }
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TokenStoreError.keychain(status) }
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw TokenStoreError.keychain(added) }
    }

    public func clearToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

/// Tests, and any context that must not touch the real keychain.
public final class InMemoryTokenStore: ZiplineTokenStore, @unchecked Sendable {
    // Guards `stored` only: `token()`, `setToken(_:)`, and `clearToken()` can be called from
    // different tasks/actors (the store is handed around as `any ZiplineTokenStore`, and
    // `Sendable` conformance promises concurrent callers are safe), and this is the one mutable
    // property that would otherwise race.
    private let lock = NSLock()
    private var stored: String?

    public init() {}

    public func token() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func setToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        // Same "empty means remove" rule as KeychainTokenStore, so the fake stays a faithful
        // stand-in for the contract tests exercised against it.
        stored = token.isEmpty ? nil : token
    }

    public func clearToken() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
