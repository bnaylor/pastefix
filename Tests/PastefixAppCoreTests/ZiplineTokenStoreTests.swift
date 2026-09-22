import Testing
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
