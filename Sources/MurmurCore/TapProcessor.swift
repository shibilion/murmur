import AVFoundation
import Foundation
import Synchronization

/// Thread-safe sample accumulator shared across tap processors for one dictation.
public final class SampleStore: Sendable {
    private let samples = Mutex<[Float]>([])

    public init() {}

    /// Append `count` samples straight from a channel pointer (no intermediate Array).
    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        samples.withLock { $0.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count)) }
    }

    public var count: Int { samples.withLock { $0.count } }

    public func snapshot() -> [Float] { samples.withLock { $0 } }
}

/// Runs on the real-time audio thread. Created per recording session for ONE input format.
/// Converts input to 16 kHz mono Float32, appends to the shared store, and throttles level reports.
/// Not main-actor isolated; its only mutable state (`lastLevelTime`) is touched solely by `process`,
/// which the audio engine calls serially from a single thread.
public final class TapProcessor: @unchecked Sendable {
    public static let outputSampleRate: Double = 16_000
    private static let levelInterval: TimeInterval = 0.033
    private static let capacitySlack: AVAudioFrameCount = 64

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double
    private let store: SampleStore
    private let levelSink: @Sendable (Float) -> Void
    private var lastLevelTime: TimeInterval = 0   // audio thread only

    public init?(inputFormat: AVAudioFormat, store: SampleStore, levelSink: @escaping @Sendable (Float) -> Void) {
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: out) else {
            return nil
        }
        converter.reset()
        self.converter = converter
        self.outputFormat = out
        self.inputSampleRate = inputFormat.sampleRate
        self.store = store
        self.levelSink = levelSink
    }

    /// Builds the tap block in a nonisolated context so it carries no actor isolation.
    /// A closure written inline inside a `@MainActor` type would be inferred main-actor isolated and trap
    /// when AVFAudio invokes it on its audio thread.
    public nonisolated func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in self.process(buffer) }
    }

    public func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let ratio = Self.outputSampleRate / inputSampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + Self.capacitySlack
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error { return }

        let frames = Int(out.frameLength)
        guard frames > 0, let channel = out.floatChannelData?[0] else { return }
        store.append(channel, count: frames)

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelTime >= Self.levelInterval {
            lastLevelTime = now
            let level = AudioMath.level(Array(UnsafeBufferPointer(start: channel, count: frames)))
            levelSink(level)
        }
    }
}
