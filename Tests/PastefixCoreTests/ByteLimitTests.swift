import Testing
@testable import PastefixCore

@Suite struct ByteLimitTests {
    @Test func binaryUnits() {
        #expect(ByteLimit.describe(65_536) == "64 KB")
        #expect(ByteLimit.describe(262_144) == "256 KB")
        #expect(ByteLimit.describe(1_048_576) == "1 MB")
        #expect(ByteLimit.describe(2_097_152) == "2 MB")
        #expect(ByteLimit.describe(1_000) == "1000 bytes")
    }
    @Test func defaults() {
        #expect(TransformLimits.defaultMaxInputBytes == 1_048_576)
        #expect(TransformLimits.defaultTimeout == 3)
    }
}
