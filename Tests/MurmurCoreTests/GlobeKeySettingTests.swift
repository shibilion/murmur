import Testing
@testable import MurmurCore

@Suite struct GlobeKeySettingTests {
    @Test func nilIsNotDoNothing() { #expect(!GlobeKeySetting.isDoNothing(nil)) }
    @Test func zeroIsDoNothing() { #expect(GlobeKeySetting.isDoNothing(0)) }
    @Test func othersAreNotDoNothing() {
        for v in [1, 2, 3, -1] { #expect(!GlobeKeySetting.isDoNothing(v)) }
    }
}
