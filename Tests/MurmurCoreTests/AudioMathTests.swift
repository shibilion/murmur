import Foundation
import Testing
@testable import MurmurCore

@Suite
struct AudioMathTests {
    @Test
    func silenceLevelIsZero() {
        let silence = Array(repeating: Float(0), count: 1_600)
        let level = AudioMath.level(silence)
        #expect(level == 0)
    }

    @Test
    func fullScaleSineLevelNearOne() {
        // 440 Hz sine wave at amplitude 1.0, sampled at 16 kHz for 1 second
        let frequency = Float(440)
        let sampleRate = Float(16_000)
        let samples = (0..<16_000).map { i in
            sin(2 * .pi * frequency * Float(i) / sampleRate)
        }
        let level = AudioMath.level(samples)
        // Sine RMS is amplitude/sqrt(2) ≈ 0.707, which is ≈ -3 dBFS
        // Mapped from [-60, 0] dBFS to [0, 1], -3 dBFS maps to about 0.95
        #expect(level >= 0.94)
    }

    @Test
    func quietSignalLevel() {
        // Constant signal at amplitude 0.001, which is -60 dBFS
        let samples = Array(repeating: Float(0.001), count: 1_600)
        let level = AudioMath.level(samples)
        #expect(level <= 0.01)
    }

    @Test
    func isUsableBoundaries() {
        // 0.29 seconds at peak 0.5 should be false (too short)
        let clip029 = AudioClip(
            samples: Array(repeating: Float(0.5), count: Int(0.29 * 16_000)),
            sampleRate: 16_000
        )
        #expect(!AudioMath.isUsable(clip029))

        // 0.30 seconds at peak 0.5 should be true (exactly at boundary)
        let clip030 = AudioClip(
            samples: Array(repeating: Float(0.5), count: Int(0.30 * 16_000)),
            sampleRate: 16_000
        )
        #expect(AudioMath.isUsable(clip030))

        // 1 second at peak 0.009 should be false (too quiet)
        let clipQuiet = AudioClip(
            samples: Array(repeating: Float(0.009), count: 16_000),
            sampleRate: 16_000
        )
        #expect(!AudioMath.isUsable(clipQuiet))

        // 1 second at peak 0.01 should be true (exactly at boundary)
        let clipQuietBoundary = AudioClip(
            samples: Array(repeating: Float(0.01), count: 16_000),
            sampleRate: 16_000
        )
        #expect(AudioMath.isUsable(clipQuietBoundary))
    }
}
