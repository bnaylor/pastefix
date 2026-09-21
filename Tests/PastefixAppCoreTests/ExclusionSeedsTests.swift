import Testing
@testable import PastefixAppCore

@Suite struct ExclusionSeedsTests {
    @Test func twelveUniqueIds() {
        let s = ExclusionSeeds.passwordManagers
        #expect(s.count == 12 && Set(s.map { $0.lowercased() }).count == 12)
        #expect(s.contains("com.1password.1password") && s.contains("com.apple.Passwords") && s.first == "com.1password.1password")
    }
}
