import AVFoundation
import Foundation
import MurmurCore

enum RecorderError: Error {
    case busy
    case engineStart(Error)
    case noInputFormat
}

/// Records the microphone to memory at 16 kHz mono Float32 while the dictation key is held.
/// All audio-thread work lives in `TapProcessor`; this class only manages engine lifecycle on the main actor.
/// Audio is never written to disk.
@MainActor
final class AudioRecorder {
    private enum State { case idle, recording, stopping }

    private let engine = AVAudioEngine()
    private var state: State = .idle
    private var store = SampleStore()

    /// Called on the main actor at most ~30 times per second with a level in [0, 1].
    var onLevel: ((Float) -> Void)?

    nonisolated(unsafe) private var configObserver: NSObjectProtocol?

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Touch the input node and prepare the engine. No tap is installed, so the mic is not live.
    func prepare() throws {
        _ = engine.inputNode
        engine.prepare()
    }

    func start() throws {
        guard state == .idle else { throw RecorderError.busy }
        store = SampleStore()
        guard installTap() else {
            state = .idle
            throw RecorderError.noInputFormat
        }
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            state = .idle
            throw RecorderError.engineStart(error)
        }
        state = .recording
    }

    /// Waits 150 ms for the tail, tears down, and returns the captured audio. Empty clip if not recording.
    func stop() async -> AudioClip {
        guard state == .recording else { return AudioClip(samples: [], sampleRate: 16_000) }
        state = .stopping
        try? await Task.sleep(for: .milliseconds(150))
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .idle
        return AudioClip(samples: store.snapshot(), sampleRate: TapProcessor.outputSampleRate)
    }

    // MARK: - Private

    /// Installs a tap using the input node's CURRENT format, with a processor built for that same format.
    private func installTap() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sink: @Sendable (Float) -> Void = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        guard format.sampleRate > 0,
              let processor = TapProcessor(inputFormat: format, store: store, levelSink: sink) else {
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: processor.makeTapBlock())
        return true
    }

    private func handleConfigurationChange() {
        switch state {
        case .recording:
            // Engine has already stopped itself. Rebuild for the new format, keeping the same store.
            engine.inputNode.removeTap(onBus: 0)
            // Keep captured samples; state stays as is so stop() still returns them.
            guard installTap() else { return }
            do {
                try engine.start()
            } catch {
                // Keep captured samples; stay .recording so stop() still returns them.
                engine.inputNode.removeTap(onBus: 0)
            }
        case .idle:
            try? prepare()
        case .stopping:
            break
        }
    }
}
