import Foundation
import Testing
import MurmurCore
@testable import MurmurEngines

private let gated = ProcessInfo.processInfo.environment["MURMUR_ENGINE_TESTS"] == "1"

func wer(reference: String, hypothesis: String) -> Double {
    func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
    }
    let r = words(reference), h = words(hypothesis)
    if r.isEmpty { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + Array(repeating: 0, count: h.count)
        for j in 1...max(h.count, 1) where j <= h.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/audio")

/// 44-byte header, Int16 mono 16 kHz.
func loadClip(_ name: String) throws -> AudioClip {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("\(name).wav"))
    let body = data.dropFirst(44)
    let samples: [Float] = body.withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
    }
    return AudioClip(samples: samples, sampleRate: 16000)
}

func reference(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent("\(name).txt"), encoding: .utf8)
}

@Suite("LocalEngineTests")
struct LocalEngineTests {
    @Test func passthroughReturnsRaw() async throws {
        let out = try await PassthroughFormatter().format(FormatRequest(raw: RawTranscript(text: "um hello  there")))
        #expect(out == "um hello  there")
    }

    @Test func werSanity() {
        #expect(wer(reference: "a b c d", hypothesis: "a x c d") == 0.25)
        #expect(wer(reference: "a b", hypothesis: "") == 1)
    }

    @Test(.enabled(if: gated)) func parakeetEnglishWER() async throws {
        let p = ParakeetTranscriber(folder: ModelLocations.murmurModels.appendingPathComponent("parakeet-v2"))
        let out = try await p.transcribe(try loadClip("en_short"), mode: .english)
        let w = wer(reference: try reference("en_short"), hypothesis: out.text)
        print("PARAKEET WER=\(w) text=\(out.text)")
        #expect(await p.isReady())
        #expect(w <= 0.35)
    }

    @Test(.enabled(if: gated)) func parakeetWarmLatency() async throws {
        let p = ParakeetTranscriber(folder: ModelLocations.murmurModels.appendingPathComponent("parakeet-v2"))
        let clip = try loadClip("en_short")
        _ = try await p.transcribe(clip, mode: .english)
        var times: [Double] = []
        for _ in 0..<3 {
            let t0 = Date()
            _ = try await p.transcribe(clip, mode: .english)
            times.append(Date().timeIntervalSince(t0))
        }
        let median = times.sorted()[1]
        print("PARAKEET WARM times=\(times) median=\(median)")
        #expect(median < 0.3)
    }

    @Test(.enabled(if: gated)) func whisperHindiOutputsDevanagari() async throws {
        let w = WhisperKitTranscriber(folder: ModelLocations.murmurModels.appendingPathComponent("whisper-large-v3-turbo"))
        let out = try await w.transcribe(try loadClip("hi_short"), mode: .indian)
        print("WHISPER HI text=\(out.text)")
        #expect(!out.text.isEmpty)
        let letters = out.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let deva = letters.filter { (0x0900...0x097F).contains($0.value) }
        #expect(!letters.isEmpty)
        #expect(Double(deva.count) / Double(max(letters.count, 1)) >= 0.5)
    }
}
