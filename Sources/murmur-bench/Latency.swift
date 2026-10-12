import Foundation
import MurmurCore
import MurmurEngines
import Synchronization

/// Accumulates the time one stage spent, across the calls of one dictation.
final class StageTimer: Sendable {
    private let total = Mutex<Double>(0)
    func add(_ s: Double) { total.withLock { $0 += s } }
    func reset() { total.withLock { $0 = 0 } }
    var seconds: Double { total.withLock { $0 } }
}

struct TimedTranscriber: Transcriber {
    let inner: any Transcriber
    let timer: StageTimer
    var id: String { inner.id }
    func isReady() async -> Bool { await inner.isReady() }
    func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript {
        let t = ContinuousClock.now
        defer { timer.add(t.duration(to: .now).seconds) }
        return try await inner.transcribe(clip, mode: mode)
    }
}

struct TimedFormatter: MurmurCore.Formatter {
    let inner: any MurmurCore.Formatter
    let timer: StageTimer
    var id: String { inner.id }
    func format(_ req: FormatRequest) async throws -> String {
        let t = ContinuousClock.now
        defer { timer.add(t.duration(to: .now).seconds) }
        return try await inner.format(req)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

final class CapturingInserter: TextInserting {
    func insert(_ text: String) async -> InsertOutcome { .pasted }
}

struct NoContext: ContextReading {
    func snapshot() async -> ContextSnapshot? { nil }
}

/// A representative workplace snapshot: about 400 characters before the cursor, 150 after, and well over 80 screen words
/// (the trimmer keeps 80). Longer than the trimmer limits on purpose, so the trimmed sizes are the real ones.
struct BenchContext: ContextReading {
    static let before = "Hi Priya, thanks for the update on the Q3 roadmap. I reviewed the Kubernetes migration plan with Rahul and the "
        + "Bengaluru platform team yesterday. The main risks are the Postgres cutover window and the Datadog alert thresholds, "
        + "so we should agree the rollback criteria before Friday. Can you also confirm whether the Razorpay sandbox keys were "
        + "rotated? Thanks again for chasing this."
    static let after = " Let me know if Thursday works for the review call, otherwise we can move it to Monday morning. "
        + "Regards, Shibili. Sent from the Tamasha engineering channel."
    static let screen = "Roadmap Q3 Kubernetes migration Postgres cutover Datadog alerts rollback criteria Razorpay sandbox keys staging "
        + "cluster Jira ticket PLAT-482 sprint planning Confluence design doc Terraform modules Helm charts Grafana dashboards "
        + "Prometheus latency p99 Redis cache invalidation Kafka consumers Bengaluru Mumbai Rahul Priya Ananya Vikram standup "
        + "retrospective backlog grooming oncall rotation PagerDuty incident postmortem Slack thread GitHub pull request review "
        + "Jenkins pipeline Docker registry Nginx ingress Cloudflare WAF Sentry release Android iOS build Firebase analytics "
        + "Mixpanel funnel retention cohort churn onboarding checkout payments wallet settlement reconciliation invoice GST"
    func snapshot() async -> ContextSnapshot? {
        ContextSnapshot(
            app: AppIdentity(name: "Slack", bundleId: "com.tinyspeck.slackmacgap"),
            beforeText: Self.before, selectedText: "", afterText: Self.after,
            screenWords: Self.screen.split(separator: " ").map(String.init), isSecureField: false)
    }
}

/// How long the user is assumed to speak between key-down and key-up in the bench.
let simulatedSpeech: Duration = .milliseconds(1500)

final class MemoryHistory: HistoryStoring {
    private let entries = Mutex<[HistoryEntry]>([])
    func append(_ e: HistoryEntry) async { entries.withLock { $0.append(e) } }
    func recent(_ n: Int) async -> [HistoryEntry] { entries.withLock { Array($0.suffix(n)) } }
    func clear() async { entries.withLock { $0.removeAll() } }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }

func runLatency(_ o: Options) async -> Int32 {
    let model = Settings().ollamaModel
    let formatterName = o["formatter"] ?? "passthrough"
    let runs = Int(o["runs"] ?? "5") ?? 5
    let withContext = o.has("context")
    guard ["ollama", "builtin", "passthrough"].contains(formatterName) else { return fail("--formatter must be ollama, builtin or passthrough", code: 2) }
    guard let root = packageRoot() else { return fail("Package.swift not found above the current directory", code: 2) }
    if formatterName == "ollama", !(await ollamaHasModel(model)) {
        return fail("Ollama is not reachable at 127.0.0.1:11434 or \(model) is not pulled (ollama pull \(model)).", code: 2)
    }

    let sttTimer = StageTimer(), fmtTimer = StageTimer()
    let modelRoot = ModelLocations.murmurModels
    let parakeet = ParakeetTranscriber(folder: modelRoot.appendingPathComponent("parakeet-v2"))
    let whisper = WhisperKitTranscriber(folder: modelRoot.appendingPathComponent("whisper-large-v3-turbo"))
    let ollama = OllamaFormatter(model: { model })
    let llama = builtinFormatter(o)
    let realFormatter: any MurmurCore.Formatter = formatterName == "ollama" ? ollama : PassthroughFormatter()
    var settings = Settings()
    if formatterName == "passthrough" { settings.strength = .off }
    if formatterName == "ollama" { settings.cleanupProvider = .ollama }
    if formatterName == "builtin" {
        settings.cleanupProvider = .builtIn
        do { try await llama.prepare() } catch { return fail("cannot load the built-in model (\(error)); pass --gguf <path>", code: 2) }
    }
    let frozen = settings
    let controller = DictationController(
        transcribers: ["parakeet": TimedTranscriber(inner: parakeet, timer: sttTimer),
                       "whisperkit": TimedTranscriber(inner: whisper, timer: sttTimer)],
        formatters: ["ollama": TimedFormatter(inner: realFormatter, timer: fmtTimer),
                     "llama": TimedFormatter(inner: llama, timer: fmtTimer),
                     "passthrough": TimedFormatter(inner: PassthroughFormatter(), timer: fmtTimer)],
        inserter: CapturingInserter(), context: withContext ? BenchContext() : NoContext(), settings: { frozen },
        history: MemoryHistory(), clock: SystemClock(),
        availability: { ProviderAvailability(builtInReady: true, appleAvailable: false, ollamaReachable: true) })

    print("formatter=\(formatterName) runs=\(runs) context=\(withContext ? "yes" : "no") speech=1.5 s (one uncounted warm-up per clip)")
    print(pad("clip", 18) + pad("dur", 8) + pad("transcribe", 13) + pad("format", 13) + pad("total", 13) + pad("raw?", 6) + "final text")
    var enShortTotal = Double.infinity, enShortFormat = Double.infinity
    for name in ["en_short", "en_long", "hi_short", "hinglish_short"] {
        let url = root.appendingPathComponent("Tests/Fixtures/audio/\(name).wav")
        guard let clip = try? loadClip(url) else { return fail("cannot read \(url.path)", code: 2) }
        let mode: DictationMode = name.hasPrefix("en") ? .english : .indian
        var stt: [Double] = [], fmt: [Double] = [], total: [Double] = []
        var last = "", lastUsedRaw = false
        for i in 0...runs {
            sttTimer.reset(); fmtTimer.reset()
            await controller.keyDown(mode: mode)
            if formatterName == "ollama" || formatterName == "builtin" {
                // As the app does right after key-down: prefill context on the model while the user speaks.
                Task {
                    guard let p = await controller.prewarmRequest() else { return }
                    if p.formatter == "llama" { await llama.warm(system: p.system, userPrefix: p.userPrefix) }
                    else { await ollama.warm(system: p.system, userPrefix: p.userPrefix) }
                }
                try? await Task.sleep(for: simulatedSpeech)
            }
            let t = ContinuousClock.now
            let result = await controller.keyUp(clip: clip, charBeforeCursor: nil)
            let elapsed = t.duration(to: .now).seconds
            guard let text = result.finalText else { return fail("\(name): dictation produced no text", code: 2) }
            last = text; lastUsedRaw = result.usedRaw
            if i == 0 { continue }
            stt.append(sttTimer.seconds); fmt.append(fmtTimer.seconds); total.append(elapsed)
        }
        if name == "en_short" { enShortTotal = median(total); enShortFormat = median(fmt) }
        print(pad(name, 18) + pad(String(format: "%.1f s", clip.duration), 8) + pad(ms(median(stt)), 13)
              + pad(ms(median(fmt)), 13) + pad(ms(median(total)), 13) + pad(lastUsedRaw ? "yes" : "no", 6) + last.replacingOccurrences(of: "\n", with: " / "))
    }
    let ok = enShortTotal <= 1.0
    print("en_short \(withContext ? "with" : "without") context: median format \(ms(enShortFormat)), median total \(ms(enShortTotal)) vs 1000 ms target: \(ok ? "PASS" : "MISS")")
    return ok ? 0 : 1
}
