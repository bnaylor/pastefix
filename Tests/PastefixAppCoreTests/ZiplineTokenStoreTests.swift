import Testing
import Security
@testable import PastefixAppCore

// Only the contract and the in-memory fake are exercised here. `KeychainTokenStore` writes to
// the real login keychain, so it is deliberately untested — the same judgement the repo already
// applies to GUI and other environment-touching code.
@Suite("Zipline token store contract")
struct ZiplineTokenStoreTests {
    @Test("a fresh store has no token")
    func empty() throws {
        #expect(try InMemoryTokenStore().token() == nil)
    }

    @Test("set then read round-trips")
    func roundTrip() throws {
        let store = InMemoryTokenStore()
        try store.setToken("tok_abc")
        #expect(try store.token() == "tok_abc")
    }

    @Test("set replaces rather than accumulating")
    func replace() throws {
        let store = InMemoryTokenStore()
        try store.setToken("first")
        try store.setToken("second")
        #expect(try store.token() == "second")
    }

    @Test("clear removes it")
    func clear() throws {
        let store = InMemoryTokenStore()
        try store.setToken("tok_abc")
        try store.clearToken()
        #expect(try store.token() == nil)
    }

    @Test("a keychain failure renders its own status, not a generic sentence")
    func keychainDetailNamesTheStatus() {
        // The distinction the upload overlay's third configure sentence rests on: "couldn't read
        // the token" has to be able to say *why*, and two different failures must not render the
        // same. `errSecUserCanceled` is what denying a Keychain permission prompt reads back as —
        // whether the prompt appeared because an ad-hoc Debug rebuild's signature no longer
        // matches the item's ACL, or because the login keychain is locked, both of which can also
        // fail outright as `errSecInteractionNotAllowed` without ever prompting. (This test used
        // to assert `errSecAuthFailed` for the former; that was never what denial produces.)
        let userCanceled = TokenStoreError.keychain(errSecUserCanceled).keychainDetail
        let locked = TokenStoreError.keychain(errSecInteractionNotAllowed).keychainDetail
        #expect(!userCanceled.isEmpty)
        #expect(!locked.isEmpty)
        #expect(userCanceled != locked)
    }

    @Test("an unknown status still produces something showable")
    func keychainDetailFallsBackToTheNumber() {
        // `SecCopyErrorMessageString` returns nil for a status it does not know; the fallback has
        // to name the number rather than leave the message with an empty parenthesis in it.
        #expect(TokenStoreError.keychain(-99_999).keychainDetail.contains("-99999"))
    }

    @Test("an empty string is stored as no token")
    func emptyStringIsNil() throws {
        // The Settings field is a text field; blanking it must mean "remove", not "the token is
        // the empty string", which would otherwise sail past a nil check and fail later as a
        // confusing 401.
        let store = InMemoryTokenStore()
        try store.setToken("tok_abc")
        try store.setToken("")
        #expect(try store.token() == nil)
    }
}
