import Foundation
import Synchronization
import Testing
import MurmurCore
@testable import MurmurEngines

private let gated = ProcessInfo.processInfo.environment["MURMUR_ENGINE_TESTS"] == "1"
private let gguf = ProcessInfo.processInfo.environment["MURMUR_GGUF"].map { URL(fileURLWithPath: $0) }

private struct StubTranscriber: Transcriber {
    let id = "parakeet"
    func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript {
        RawTranscript(text: "um hello world how are you")
    }
}

private final class StubInserter: TextInserting {
    let texts = Mutex<[String]>([])
    func insert(_ text: String) async -> InsertOutcome { texts.withLock { $0.append(text) }; return .pasted }
}

private struct NoContext: ContextReading {
    func snapshot() async -> ContextSnapshot? { nil }
}

private final class NullHistory: HistoryStoring {
    func append(_ e: HistoryEntry) async {}
    func recent(_ n: Int) async -> [HistoryEntry] { [] }
    func clear() async {}
}

private func request(_ text: String, context: ContextSnapshot? = nil) -> FormatRequest {
    FormatRequest(raw: RawTranscript(text: text), context: context, dictionary: ["Priya"])
}

@Suite("LlamaFormatterTests")
struct LlamaFormatterTests {
    @Test func llamaLoadFailureFallsBackToRaw() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("llama-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        var settings = Settings()
        settings.cleanupProvider = .builtIn
        let frozen = settings
        let inserter = StubInserter()
        let controller = DictationController(
            transcribers: ["parakeet": StubTranscriber()],
            formatters: ["llama": LlamaFormatter(folder: empty), "passthrough": PassthroughFormatter()],
            inserter: inserter, context: NoContext(), settings: { frozen }, history: NullHistory(),
            clock: SystemClock(),
            availability: { ProviderAvailability(builtInReady: true, appleAvailable: false, ollamaReachable: false) })
        let notices = Mutex<[Notice]>([])
        let events = controller.events
        let collector = Task { for await e in events { if case .notice(let n) = e { notices.withLock { $0.append(n) } } } }
        await controller.keyDown(mode: .english)
        let clip = AudioClip(samples: Array(repeating: 0.5, count: 16_000), sampleRate: 16_000)
        let r = await controller.keyUp(clip: clip, charBeforeCursor: nil)
        for _ in 0..<200 where !notices.withLock({ $0 }).contains(.cleanupOff) { try await Task.sleep(for: .milliseconds(10)) }
        collector.cancel()
        #expect(r.usedRaw)
        #expect(inserter.texts.withLock { $0 } == ["um hello world how are you"])
        #expect(notices.withLock { $0 }.contains(.cleanupOff))
    }

    @Test func concurrentPrepareLoadsOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llama-conc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a model".utf8).write(to: dir.appendingPathComponent("m.gguf"))
        let loads = Mutex(0)
        let f = LlamaFormatter(folder: dir, modelFile: "m.gguf", beforeLoad: {
            loads.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(200))
        })
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<4 { g.addTask { try? await f.prepare() } }
            g.addTask { await f.warm(system: "s", userPrefix: "u") }
        }
        #expect(loads.withLock { $0 } == 1)
        // A failed load is not cached: a later call tries again.
        try? await f.prepare()
        #expect(loads.withLock { $0 } == 2)
    }

    @Test func promptMatchesHintsStyle() {
        let ctx = ContextSnapshot(app: AppIdentity(name: "Slack", bundleId: "x"), beforeText: "Dear Priya, Kubernetes",
                                  selectedText: "", afterText: "", screenWords: ["Raghunathan"], isSecureField: false)
        let req = request("um lets meet on tuesday", context: ctx)
        let p = LlamaFormatter.promptParts(for: req)
        #expect(p.system == PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone, contextStyle: .hints))
        #expect(p.userPrefix.hasPrefix("<app>Slack</app>\n<hints>"))
        #expect(!p.userPrefix.contains("<before_cursor>"))
        #expect(p.transcript == "<transcript>um lets meet on tuesday</transcript>")
        #expect(p.userPrefix + p.transcript == PromptBuilder.user(req, includeContext: true, style: .hints))
        let chat = LlamaFormatter.chatML(system: p.system, user: p.userPrefix + p.transcript)
        #expect(chat.hasPrefix("<|im_start|>system\n"))
        #expect(chat.hasSuffix("<|im_end|>\n<|im_start|>assistant\n"))
    }

    @Test func prefixReuseDetectsMismatch() {
        #expect(LlamaFormatter.commonPrefixLength([1, 2, 3], [1, 2, 3, 4, 5]) == 3)
        #expect(LlamaFormatter.commonPrefixLength([1, 2, 9], [1, 2, 3, 4]) == 2)
        #expect(LlamaFormatter.commonPrefixLength([7], [1, 2]) == 0)
        #expect(LlamaFormatter.commonPrefixLength([], [1]) == 0)
    }

    @Test func endOfTurnMarkerIsCutAndThinkStripped() {
        #expect(LlamaFormatter.cutAtEnd("Hello.<|im_end|>junk") == "Hello.")
        #expect(OllamaFormatter.stripThink("<think>x</think>\nHi.\n") == "Hi.")
    }

    @Test(.enabled(if: gated && gguf != nil)) func llamaCleansSelfCorrection() async throws {
        let f = LlamaFormatter(folder: gguf!.deletingLastPathComponent(), modelFile: gguf!.lastPathComponent)
        let out = try await f.format(request("um so lets meet on tuesday no wait wednesday at ten"))
        print("LLAMA OUT: \(out)")
        #expect(out.contains("Wednesday"))
        #expect(!out.contains("Tuesday"))
    }

    @Test(.enabled(if: gated && gguf != nil)) func llamaWarmLatency() async throws {
        let f = LlamaFormatter(folder: gguf!.deletingLastPathComponent(), modelFile: gguf!.lastPathComponent)
        let ctx = ContextSnapshot(app: AppIdentity(name: "Slack", bundleId: "x"), beforeText: "Dear Priya",
                                  selectedText: "", afterText: "", screenWords: ["Raghunathan"], isSecureField: false)
        let req = request("um so lets meet on tuesday no wait wednesday at ten", context: ctx)
        let p = LlamaFormatter.promptParts(for: req)
        try await f.prepare()
        _ = try await f.format(req)   // shader warm-up
        await f.warm(system: p.system, userPrefix: p.userPrefix)
        let t = ContinuousClock.now
        let out = try await f.format(req)
        let s = t.duration(to: .now)
        let secs = Double(s.components.seconds) + Double(s.components.attoseconds) / 1e18
        print("LLAMA WARM \(secs) s: \(out)")
        #expect(secs < 0.6)
    }
}
