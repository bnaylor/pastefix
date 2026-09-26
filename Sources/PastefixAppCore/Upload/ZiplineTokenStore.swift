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

    /// The Security framework's own sentence for this status, for a UI that has to tell the
    /// user *which* wall it hit. Lives on the error rather than in a view because two surfaces
    /// ask — the Upload settings tab and the upload overlay's configure state — and a keychain
    /// failure that reads two different ways in two places is worse than either wording.
    ///
    /// Safe to show: the payload is an `OSStatus`, never the token.
    public var keychainDetail: String {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        }
    }
}

/// Generic-password item under a fixed service. The token is the one piece of Pastefix's
/// configuration that must not sit in `UserDefaults` JSON, which is readable by anything
/// running as this user.
///
/// **This is the legacy (file-based) login keychain, and it carries no `kSecAttrAccessible`.**
/// That attribute was set here and was doing nothing: it is honoured only by the
/// data-protection keychain (`kSecUseDataProtectionKeychain: true`), so on this keychain it
/// stated an intent the stored item does not carry. Stating an intent the item does not have is
/// worse than not stating it, because the next reader believes it.
///
/// Adopting the data-protection keychain — which would make `WhenUnlocked` real — was measured
/// rather than assumed, and it is not available to this app:
///
/// - Ad-hoc signed (a plain Debug build): `SecItemAdd` with `kSecUseDataProtectionKeychain`
///   returns `errSecMissingEntitlement` (-34018).
/// - Signed `Developer ID Application: … (RMKGLPG4K4)` with this app's real entitlements
///   (`com.apple.security.cs.allow-jit` alone), hardened runtime on — the shipping
///   configuration: the same -34018. A team-ID signature is not sufficient.
/// - Adding `keychain-access-groups` to get past it makes the process **SIGKILL at launch**
///   (exit 137), because on macOS that entitlement has to be authorised by an embedded
///   provisioning profile. Embedding one would change the release pipeline and the entitlements
///   file that invariant 11 pins, to buy an accessibility class for a keychain item that is
///   already protected by the login keychain's own lock state.
///
/// So the attribute is dropped rather than made real, and what the item *actually* carries is
/// recorded here instead: a legacy keychain item gets an ACL bound to the signing identity of
/// the app that created it. Consequences worth knowing before reading a bug report:
///
/// - A **Developer ID release** build reads it silently, across versions: the signing identity
///   is stable, so the ACL keeps matching.
/// - An **ad-hoc Debug rebuild** changes the cdhash every build, so the ACL no longer matches
///   the caller: `token()` can prompt for permission — denying any such Keychain prompt reads
///   back as `errSecUserCanceled` (-128), not `errSecAuthFailed`, which this comment used to
///   claim — or fail outright without prompting, depending on the session. Re-signing the Debug
///   build (`docs/gui-automation.md`, the same step the Accessibility grant needs) makes it
///   stable again.
///
/// That second case is a *read failure*, not "no token", and the surfaces that ask must say so —
/// see `TokenStoreError.keychainDetail` and the upload overlay's configure state.
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
