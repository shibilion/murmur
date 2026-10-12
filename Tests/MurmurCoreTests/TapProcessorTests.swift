import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MurmurCore

private func sineBuffer(rate: Double, channels: AVAudioChannelCount = 1, frames: Int = 1_024,
                        amplitude: Float = 0.5, startFrame: Int = 0) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    for ch in 0..<Int(channels) {
        let p = buf.floatChannelData![ch]
        for i in 0..<frames {
            p[i] = amplitude * sinf(2 * .pi * 440 * Float(startFrame + i) / Float(rate))
        }
    }
    return buf
}

private func feed(_ proc: TapProcessor, rate: Double, channels: AVAudioChannelCount = 1, buffers: Int) {
    for n in 0..<buffers {
        proc.process(sineBuffer(rate: rate, channels: channels, startFrame: n * 1_024))
    }
}

private func makeProcessor(_ f: AVAudioFormat, _ store: SampleStore,
                           sink: @escaping @Sendable (Float) -> Void = { _ in }) throws -> TapProcessor {
    try #require(TapProcessor(inputFormat: f, store: store, levelSink: sink))
}

private func format(_ rate: Double, _ ch: AVAudioChannelCount = 1) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: ch, interleaved: false)!
}

@Suite struct TapProcessorTests {
    @Test func downsamples48kTo16k() throws {
        let store = SampleStore()
        let proc = try makeProcessor(format(48_000), store)
        feed(proc, rate: 48_000, buffers: 10)
        let expected = 10.0 * 1_024 / 3
        #expect(abs(Double(store.count) - expected) <= 64)
        let peak = AudioMath.peak(store.snapshot())
        #expect(peak > 0.4 && peak < 0.6)
    }

    @Test func upsamples8kWithoutTruncation() throws {
        let store = SampleStore()
        let proc = try makeProcessor(format(8_000), store)
        feed(proc, rate: 8_000, buffers: 10)
        #expect(abs(store.count - 20_480) <= 64)
    }

    @Test func stereoInputMixedToMono() throws {
        let store = SampleStore()
        let proc = try makeProcessor(format(44_100, 2), store)
        feed(proc, rate: 44_100, channels: 2, buffers: 10)
        #expect(store.count > 0)
        #expect(abs(Double(store.count) - 10.0 * 1_024 * 16_000 / 44_100) <= 64)
    }

    @Test func levelSinkThrottled() throws {
        let calls = Mutex(0)
        let store = SampleStore()
        let proc = try makeProcessor(format(48_000), store, sink: { _ in
            calls.withLock { $0 += 1 }
        })
        let start = ProcessInfo.processInfo.systemUptime
        feed(proc, rate: 48_000, buffers: 100)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let n = calls.withLock { $0 }
        #expect(n >= 1)
        #expect(Double(n) <= elapsed / 0.033 + 2)
    }

    @Test func sharedStoreKeepsSamplesAcrossProcessors() throws {
        let store = SampleStore()
        let a = try makeProcessor(format(48_000), store)
        feed(a, rate: 48_000, buffers: 5)
        let afterA = store.count
        #expect(afterA > 0)
        let b = try makeProcessor(format(8_000), store)
        feed(b, rate: 8_000, buffers: 5)
        let total = store.count
        #expect(total > afterA)
        #expect(abs(total - afterA - 10_240) <= 64)
    }

    /// Pins that the factory-built block is safe to call from a plain background queue (as AVFAudio does).
    /// The original crash (MainActor isolation check in an app-side closure) cannot be reproduced in MurmurCore.
    @Test func tapBlockRunsOffMainWithoutIsolationTrap() throws {
        let store = SampleStore()
        let proc = try makeProcessor(format(48_000), store)
        let block = proc.makeTapBlock()
        let queue = DispatchQueue(label: "test.tap.audio")
        let done = DispatchSemaphore(value: 0)
        queue.async {
            for n in 0..<5 {
                block(sineBuffer(rate: 48_000, startFrame: n * 1_024), AVAudioTime(sampleTime: 0, atRate: 48_000))
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(store.count > 0)
    }
}
