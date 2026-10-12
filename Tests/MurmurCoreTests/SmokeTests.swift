import Testing
@testable import MurmurCore

@Test func clipDuration() {
    #expect(AudioClip(samples: .init(repeating: 0, count: 16_000), sampleRate: 16_000).duration == 1.0)
}
