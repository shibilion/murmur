import Foundation
import Testing
@testable import MurmurCore

// MARK: - Harness

private let app = AppIdentity(name: "Notes", bundleId: "com.app")

private func snapshot(secure: Bool = false) -> ContextSnapshot {
    ContextSnapshot(
        app: app, beforeText: "Dear Priya,", selectedText: "", afterText: "",
        screenWords: ["Kubernetes"], isSecureField: secure
    )
}

private func clip(seconds: Double = 1, amplitude: Float = 0.5) -> AudioClip {
    AudioClip(samples: Array(repeating: amplitude, count: Int(16_000 * seconds)), sampleRate: 16_000)
}

private final class Harness: Sendable {
    let clock = VirtualClock()
    let inserter: FakeInserter
    let history = FakeHistory()
    let transcribers: [String: any Transcriber]
    let formatters: [String: any MurmurCore.Formatter]
    let controller: DictationController

    init(
        settings: Settings = Settings(),
        context: ContextSnapshot? = snapshot(),
        insertOutcome: InsertOutcome = .pasted,
        transcribers: (VirtualClock) -> [FakeTranscriber] = { c in
            [FakeTranscriber(id: "parakeet", text: "hello wrld how are you", clock: c)]
        },
        formatters: (VirtualClock) -> [FakeFormatter] = { c in
            [FakeFormatter(id: "ollama", behavior: .fixed("Hello world, how are you?"), clock: c)]
        },
        extraFormatters: [String: any MurmurCore.Formatter] = [:]
    ) {
        let inserter = FakeInserter(outcome: insertOutcome)
        self.inserter = inserter
        let ts = Dictionary(uniqueKeysWithValues: transcribers(clock).map { ($0.id, $0 as any Transcriber) })
        var fs = Dictionary(uniqueKeysWithValues: formatters(clock).map { ($0.id, $0 as any MurmurCore.Formatter) })
        fs.merge(extraFormatters) { $1 }
        self.transcribers = ts
        self.formatters = fs
        controller = DictationController(
            transcribers: ts, formatters: fs, inserter: inserter,
            context: FakeContext(value: context), settings: { settings },
            history: history, clock: clock
        )
    }

    func dictate(
        mode: DictationMode = .english, clip: AudioClip = clip(), charBefore: Character? = nil
    ) async -> DictationResult {
        await controller.keyDown(mode: mode)
        return await controller.keyUp(clip: clip, charBeforeCursor: charBefore)
    }
}

/// Reads events up to and including the first return to idle.
private func drain(_ events: AsyncStream<DictationEvent>) async -> [DictationEvent] {
    var out: [DictationEvent] = []
    for await e in events {
        out.append(e)
        if e == .stateChanged(.idle) { break }
    }
    return out
}

private func notices(_ events: [DictationEvent]) -> [Notice] {
    events.compactMap { if case .notice(let n) = $0 { n } else { nil } }
}

// MARK: - Tests

@Test func happyPath() async {
    let h = Harness()
    let r = await h.dictate()
    #expect(r.finalText == "Hello world, how are you?")
    #expect(r.raw == "hello wrld how are you")
    #expect(!r.usedRaw)
    #expect(r.outcome == .pasted)
    #expect(h.inserter.texts == ["Hello world, how are you?"])
    #expect(h.history.all.count == 1)
    #expect(h.history.all[0].raw == "hello wrld how are you")
    #expect(h.history.all[0].final == "Hello world, how are you?")
    #expect(h.history.all[0].appBundleId == "com.app")
    #expect(await h.controller.state == .idle)
}

@Test func statesAreEmittedInOrder() async {
    let h = Harness()
    _ = await h.dictate()
    let events = await drain(h.controller.events)
    #expect(events == [
        .stateChanged(.recording), .stateChanged(.transcribing), .stateChanged(.formatting),
        .stateChanged(.inserting), .stateChanged(.idle),
    ])
}

@Test func shortClipDiscarded() async {
    let h = Harness()
    let r = await h.dictate(clip: clip(seconds: 0.2))
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(h.history.all.isEmpty)
    #expect(notices(await drain(h.controller.events)) == [.nothingHeard])
    #expect(await h.controller.state == .idle)
}

@Test func silentClipDiscarded() async {
    let h = Harness()
    let r = await h.dictate(clip: clip(amplitude: 0.005))
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(notices(await drain(h.controller.events)) == [.nothingHeard])
}

@Test func emptyTranscriptIsNothingHeard() async {
    let h = Harness(transcribers: { [FakeTranscriber(id: "parakeet", text: "  \n", clock: $0)] })
    let r = await h.dictate()
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(notices(await drain(h.controller.events)) == [.nothingHeard])
}

@Test func missingSpeechModelShowsDownloadingNotice() async {
    let h = Harness(transcribers: { [FakeTranscriber(id: "parakeet", text: nil, modelMissing: true, clock: $0)] })
    let r = await h.dictate()
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(notices(await drain(h.controller.events)) == [.speechModelDownloading])
}

@Test func transcriptionFailureWithNoFallbackInsertsNothing() async {
    let h = Harness(transcribers: { [FakeTranscriber(id: "parakeet", text: nil, clock: $0)] })
    let r = await h.dictate()
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(h.history.all.isEmpty)
    #expect(notices(await drain(h.controller.events)) == [.transcriptionFailed])
    #expect(await h.controller.state == .idle)
}

@Test func formatterThrowsUsesRaw() async {
    let h = Harness(formatters: { [FakeFormatter(id: "ollama", behavior: .fail, clock: $0)] })
    let r = await h.dictate()
    #expect(r.usedRaw)
    #expect(r.finalText == "hello wrld how are you")
    #expect(h.inserter.texts == ["hello wrld how are you"])
    #expect(notices(await drain(h.controller.events)) == [.cleanupOff])
}

@Test func formatterOverBudgetUsesRaw() async {
    let h = Harness(formatters: { [FakeFormatter(id: "ollama", delay: 60, clock: $0)] })
    let task = Task { await h.dictate() }
    await h.clock.waitForSleepers(2)
    h.clock.advance(by: 3)   // budget is 2.0 + 0.015 * 5 = 2.075 s
    let r = await task.value
    #expect(r.usedRaw)
    #expect(h.inserter.texts == ["hello wrld how are you"])
    #expect(notices(await drain(h.controller.events)) == [.cleanupOff])
}

@Test func longDictationGetsScaledTimeout() async {
    let raw = Array(repeating: "word", count: 300).joined(separator: " ")
    let h = Harness(
        transcribers: { [FakeTranscriber(id: "parakeet", text: raw, clock: $0)] },
        formatters: { [FakeFormatter(id: "ollama", delay: 5, clock: $0)] }
    )
    let task = Task { await h.dictate() }
    await h.clock.waitForSleepers(2)
    #expect(h.clock.requestedDurations.contains { abs($0 - 6.5) < 0.0001 })
    h.clock.advance(by: 5)   // formatter finishes; the 6.5 s budget has not elapsed
    let r = await task.value
    #expect(!r.usedRaw)
    #expect(r.finalText == raw + ".")
}

@Test func cloudTranscriberTimeoutFallsBackLocal() async {
    let h = Harness(
        settings: Settings(cloudBoost: true),
        transcribers: { c in [
            FakeTranscriber(id: "groq", text: "cloud text", delay: 100, clock: c),
            FakeTranscriber(id: "parakeet", text: "local text", clock: c),
        ] },
        formatters: { c in [FakeFormatter(id: "claude", clock: c), FakeFormatter(id: "ollama", clock: c)] }
    )
    let task = Task { await h.dictate() }
    await h.clock.waitForSleepers(2)
    #expect(h.clock.requestedDurations.contains(3.0))
    h.clock.advance(by: 3)
    let r = await task.value
    #expect(r.raw == "local text")
    #expect(h.inserter.texts == ["local text."])
    #expect(notices(await drain(h.controller.events)) == [.usedLocal])
}

@Test func cloudFormatterFailureFallsBackToLocalFormatter() async {
    let h = Harness(
        settings: Settings(cloudBoost: true),
        transcribers: { c in [
            FakeTranscriber(id: "groq", text: "cloud text", clock: c),
            FakeTranscriber(id: "parakeet", text: "local text", clock: c),
        ] },
        formatters: { c in [
            FakeFormatter(id: "claude", behavior: .fail, clock: c),
            FakeFormatter(id: "ollama", behavior: .fixed("Cloud text!"), clock: c),
        ] }
    )
    let r = await h.dictate()
    #expect(r.finalText == "Cloud text!")
    #expect(!r.usedRaw)
    #expect(notices(await drain(h.controller.events)) == [.usedLocal])
}

@Test func rewriteRejected() async {
    let raw = "what time is it in Paris today"
    let h = Harness(
        transcribers: { [FakeTranscriber(id: "parakeet", text: raw, clock: $0)] },
        formatters: { [FakeFormatter(id: "ollama", behavior: .fixed("It is currently three in the afternoon in Paris."), clock: $0)] }
    )
    let r = await h.dictate()
    #expect(r.usedRaw)
    #expect(h.inserter.texts == [raw])
}

@Test func cancelDuringRecordingInsertsNothing() async {
    let h = Harness()
    await h.controller.keyDown(mode: .english)
    #expect(await h.controller.state == .recording)
    await h.controller.cancel()
    #expect(await h.controller.state == .idle)
    let r = await h.controller.keyUp(clip: clip(), charBeforeCursor: nil)
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(h.history.all.isEmpty)
}

@Test func cancelWhileTranscribingInsertsNothing() async {
    let h = Harness(transcribers: { [FakeTranscriber(id: "parakeet", text: "hello there", delay: 10, clock: $0)] })
    let task = Task { await h.dictate() }
    await h.clock.waitForSleepers(1)
    await h.controller.cancel()
    h.clock.advance(by: 10)
    let r = await task.value
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(h.history.all.isEmpty)
    #expect(await h.controller.state == .idle)
}

@Test func copiedOnlyEmitsNotice() async {
    let h = Harness(insertOutcome: .copiedOnly)
    let r = await h.dictate()
    #expect(r.outcome == .copiedOnly)
    #expect(notices(await drain(h.controller.events)) == [.copiedPressCmdV])
    #expect(h.history.all.count == 1)
}

@Test func snippetsAppliedAfterFormatting() async {
    let h = Harness(
        settings: Settings(snippets: [Snippet(trigger: "my email", expansion: "a@b.com")]),
        transcribers: { [FakeTranscriber(id: "parakeet", text: "please send it to my email", clock: $0)] },
        formatters: { [FakeFormatter(id: "ollama", behavior: .fixed("Please send it to my email."), clock: $0)] }
    )
    let r = await h.dictate()
    #expect(r.finalText?.contains("a@b.com") == true)
    #expect(h.inserter.texts.first?.contains("a@b.com") == true)
}

@Test func leadingSpaceAddedAfterNonWhitespace() async {
    let h = Harness()
    let r = await h.dictate(charBefore: "k")
    #expect(r.finalText == " Hello world, how are you?")
}

@Test func modelNotReadyEmitsWarmingUp() async {
    let h = Harness(transcribers: { [FakeTranscriber(id: "parakeet", text: "hello wrld how are you", ready: false, clock: $0)] })
    let r = await h.dictate()
    #expect(r.finalText == "Hello world, how are you?")
    #expect(h.inserter.texts.count == 1)
    #expect(notices(await drain(h.controller.events)) == [.warmingUp])
}

@Test func passthroughRuleSkipsFormatter() async {
    let formatter = FakeFormatter(id: "ollama", clock: VirtualClock())
    let settings = Settings(rules: [AppRule(bundleId: "com.app", cleanupOff: true)])
    let h = Harness(settings: settings, formatters: { _ in [formatter] })
    let r = await h.dictate()
    #expect(r.finalText == "hello wrld how are you")
    #expect(formatter.requests.isEmpty)
    #expect(notices(await drain(h.controller.events)).isEmpty)
}

@Test func contextIsTrimmedAndSentToLocalFormatter() async {
    let formatter = FakeFormatter(id: "ollama", behavior: .fixed("Hello world, how are you?"), clock: VirtualClock())
    let h = Harness(settings: Settings(dictionary: ["Priya"]), formatters: { _ in [formatter] })
    _ = await h.dictate()
    #expect(formatter.requests.first?.context?.beforeText == "Dear Priya,")
    #expect(formatter.requests.first?.dictionary == ["Priya"])
}

@Test func secureFieldSendsNoContext() async {
    let formatter = FakeFormatter(id: "ollama", behavior: .fixed("Hello world, how are you?"), clock: VirtualClock())
    let h = Harness(context: snapshot(secure: true), formatters: { _ in [formatter] })
    _ = await h.dictate()
    #expect(formatter.requests.first?.context == nil)
}

@Test func cloudWithoutContextConsentSendsNoContextOrDictionary() async {
    let claude = FakeFormatter(id: "claude", behavior: .fixed("Hello world, how are you?"), clock: VirtualClock())
    let h = Harness(
        settings: Settings(cloudBoost: true, sendContextToCloud: false, dictionary: ["Priya"]),
        transcribers: { c in [
            FakeTranscriber(id: "groq", text: "hello wrld how are you", clock: c),
            FakeTranscriber(id: "parakeet", text: "x", clock: c),
        ] },
        formatters: { _ in [claude, FakeFormatter(id: "ollama", clock: VirtualClock())] }
    )
    _ = await h.dictate()
    #expect(claude.requests.first?.context == nil)
    #expect(claude.requests.first?.dictionary == [])
}

@Test func nonCooperativeFormatterStillTimesOut() async {
    let gated = GatedFormatter(id: "ollama")
    let h = Harness(formatters: { _ in [] })
    let controller = DictationController(
        transcribers: h.transcribers, formatters: ["ollama": gated], inserter: h.inserter,
        context: FakeContext(value: snapshot()), settings: { Settings() },
        history: h.history, clock: h.clock
    )
    let task = Task { () -> DictationResult in
        await controller.keyDown(mode: .english)
        return await controller.keyUp(clip: clip(), charBeforeCursor: nil)
    }
    await gated.waitUntilEntered()
    await h.clock.waitForSleepers(1)
    h.clock.advance(by: 3)
    let r = await task.value   // must finish although the formatter ignores cancellation
    #expect(r.usedRaw)
    #expect(r.finalText == "hello wrld how are you")
    gated.release(with: "late result")   // dropped; nothing leaks
    #expect(h.inserter.texts == ["hello wrld how are you"])
}

private func gatedHarness(_ gated: GatedFormatter, settings: Settings = Settings(), context: ContextSnapshot? = snapshot()) -> Harness {
    Harness(settings: settings, context: context, formatters: { _ in [] }, extraFormatters: ["ollama": gated])
}

@Test func keyDownWhileFormattingEmitsBusyAndDoesNotDisturb() async {
    let gated = GatedFormatter(id: "ollama")
    let h = gatedHarness(gated)
    let a = Task { await h.dictate() }
    await gated.waitUntilEntered()
    await h.controller.keyDown(mode: .english)
    let b = await h.controller.keyUp(clip: clip(), charBeforeCursor: nil)
    #expect(b.finalText == nil)
    #expect(await h.controller.state == .formatting)
    gated.release(with: "Hello world, how are you?")
    let ra = await a.value
    #expect(ra.finalText == "Hello world, how are you?")
    #expect(h.inserter.texts == ["Hello world, how are you?"])
    #expect(h.history.all.count == 1)
    #expect(notices(await drain(h.controller.events)).contains(.busy))
}

@Test func cancelDuringFormattingInsertsNothing() async {
    let gated = GatedFormatter(id: "ollama")
    let h = gatedHarness(gated)
    let a = Task { await h.dictate() }
    await gated.waitUntilEntered()
    await h.controller.cancel()
    gated.release(with: "Hello world, how are you?")
    let r = await a.value
    #expect(r.finalText == nil)
    #expect(h.inserter.texts.isEmpty)
    #expect(h.history.all.isEmpty)
    #expect(await h.controller.state == .idle)
}

@Test func secureFieldStillInserts() async {
    let formatter = FakeFormatter(id: "ollama", behavior: .fixed("Hello world, how are you?"), clock: VirtualClock())
    let h = Harness(context: snapshot(secure: true), formatters: { _ in [formatter] })
    let r = await h.dictate()
    #expect(formatter.requests.first?.context == nil)
    #expect(r.finalText == "Hello world, how are you?")
    #expect(h.inserter.texts == ["Hello world, how are you?"])
}

@Test func cloudFormatterUsesThreeSecondBudget() async {
    let raw = "one two three four five six seven eight nine ten"
    let h = Harness(
        settings: Settings(cloudBoost: true),
        transcribers: { c in [
            FakeTranscriber(id: "groq", text: raw, clock: c),
            FakeTranscriber(id: "parakeet", text: "x", clock: c),
        ] },
        formatters: { c in [
            FakeFormatter(id: "claude", behavior: .fixed("never"), delay: 100, clock: c),
            FakeFormatter(id: "ollama", clock: c),
        ] }
    )
    let task = Task { await h.dictate() }
    await h.clock.waitForSleepers(2)
    #expect(h.clock.requestedDurations.contains { abs($0 - 3.15) < 0.0001 })
    h.clock.advance(by: 4)
    let r = await task.value
    #expect(r.finalText == raw + ".")
    #expect(notices(await drain(h.controller.events)) == [.usedLocal])
}

@Test func ignoredKeyDownWithoutKeyUpDoesNotSwallowNextDictation() async {
    let gated = GatedFormatter(id: "ollama")
    let h = gatedHarness(gated)
    let a = Task { await h.dictate() }
    await gated.waitUntilEntered()
    await h.controller.keyDown(mode: .english)   // B: ignored (busy), never sends a keyUp
    gated.release(with: "Hello world, how are you?")
    _ = await a.value
    #expect(await h.controller.state == .idle)
    let c = Task { await h.dictate() }
    await gated.waitUntilSuspended()
    gated.release(with: "Hello world, how are you?")
    let rc = await c.value
    #expect(rc.finalText == "Hello world, how are you?")
    #expect(h.inserter.texts == ["Hello world, how are you?", "Hello world, how are you?"])
}

@Test func prewarmPrefixMatchesFormatterRequestPrefix() async throws {
    var settings = Settings()
    settings.dictionary = ["Sarvam"]
    let h = Harness(settings: settings)
    await h.controller.keyDown(mode: .english)
    let warm = try #require(await h.controller.prewarmRequest())
    let r = await h.controller.keyUp(clip: clip(), charBeforeCursor: nil)
    #expect(r.finalText != nil)
    let fake = try #require(h.formatters["ollama"] as? FakeFormatter)
    let req = try #require(fake.requests.first)
    // The Harness routes to "ollama", so the warm-up and the real request both use the hints style.
    let parts = PromptBuilder.userParts(req, includeContext: req.context != nil, style: .hints)
    #expect(!warm.userPrefix.isEmpty)
    #expect(warm.userPrefix.contains("<hints>"))
    #expect(!warm.userPrefix.contains("<before_cursor>"))
    #expect(warm.userPrefix == parts.prefix)
    #expect(PromptBuilder.user(req, includeContext: req.context != nil, style: .hints).hasPrefix(warm.userPrefix))
    #expect(warm.system == PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone, contextStyle: .hints))
}

@Test func prewarmIsNilWhenFormatterIsNotOllama() async {
    var settings = Settings()
    settings.strength = .off
    let h = Harness(settings: settings)
    await h.controller.keyDown(mode: .english)
    #expect(await h.controller.prewarmRequest() == nil)
}

@Test func prewarmIsNilWhenNotRecording() async {
    let h = Harness()
    #expect(await h.controller.prewarmRequest() == nil)
}

@Test func builtInAvailabilityRoutesToLlamaAndPrewarms() async throws {
    var settings = Settings()
    settings.dictionary = ["Sarvam"]
    let frozen = settings
    let clock = VirtualClock()
    let llama = FakeFormatter(id: "llama", behavior: .fixed("Hello world, how are you?"), clock: clock)
    let inserter = FakeInserter()
    let controller = DictationController(
        transcribers: ["parakeet": FakeTranscriber(id: "parakeet", text: "hello wrld how are you", clock: clock)],
        formatters: ["llama": llama, "passthrough": FakeFormatter(id: "passthrough", clock: clock)],
        inserter: inserter, context: FakeContext(value: snapshot()), settings: { frozen },
        history: FakeHistory(), clock: clock,
        availability: { ProviderAvailability(builtInReady: true, appleAvailable: false, ollamaReachable: false) })
    await controller.keyDown(mode: .english)
    let warm = try #require(await controller.prewarmRequest())
    #expect(warm.userPrefix.contains("<hints>"))
    let r = await controller.keyUp(clip: clip(), charBeforeCursor: nil)
    #expect(r.finalText == "Hello world, how are you?")
    #expect(llama.requests.count == 1)
}
