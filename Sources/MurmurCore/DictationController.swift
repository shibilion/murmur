import Foundation
import Synchronization

public enum DictationState: Sendable, Equatable {
    case idle, recording, transcribing, formatting, inserting
}

public enum Notice: Sendable, Equatable {
    case usedLocal
    case copiedPressCmdV
    case cleanupOff
    case nothingHeard
    case warmingUp
    case transcriptionFailed
    /// The speech model is still downloading or being verified, so it can't transcribe yet.
    case speechModelDownloading
    /// A new key press arrived while the previous dictation was still processing; it was ignored.
    case busy
}

public enum DictationEvent: Sendable, Equatable {
    case stateChanged(DictationState)
    case notice(Notice)
}

public struct DictationResult: Sendable, Equatable {
    public var finalText: String?
    public var raw: String?
    public var usedRaw: Bool
    public var outcome: InsertOutcome?

    public init(finalText: String? = nil, raw: String? = nil, usedRaw: Bool = false, outcome: InsertOutcome? = nil) {
        self.finalText = finalText
        self.raw = raw
        self.usedRaw = usedRaw
        self.outcome = outcome
    }
}

/// Adopted by engine errors that can say "my model isn't installed or verified yet".
public protocol ModelUnavailableError: Error {
    var isModelMissing: Bool { get }
}

private struct TimedOut: Error {}

/// Runs `op` against a deadline. Returns or throws as soon as either side finishes, then cancels the loser
/// without waiting for it, so an engine that ignores cancellation cannot hold the caller past the budget.
/// A late result from the loser is dropped.
private func withTimeout<T: Sendable>(
    _ budget: TimeInterval,
    clock: any Clock,
    _ op: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            race.start(cont)
            let engine = Task {
                do { race.finish(.success(try await op())) } catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    try await clock.sleep(budget)
                    race.finish(.failure(TimedOut()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            race.attach([engine, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Resumes its continuation exactly once and cancels the racing tasks when it does.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var tasks: [Task<Void, Never>] = []
        var done = false
        var early: Result<T, Error>?
    }
    private let state = Mutex(State())

    func start(_ cont: CheckedContinuation<T, Error>) {
        let early = state.withLock { st -> Result<T, Error>? in
            if let r = st.early { return r }
            st.continuation = cont
            return nil
        }
        if let early { cont.resume(with: early) }
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        let cancelNow = state.withLock { st -> Bool in
            if st.done { return true }
            st.tasks = tasks
            return false
        }
        if cancelNow { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<T, Error>) {
        let (cont, tasks) = state.withLock { st -> (CheckedContinuation<T, Error>?, [Task<Void, Never>]) in
            if st.done { return (nil, []) }
            st.done = true
            let c = st.continuation
            st.continuation = nil
            if c == nil { st.early = result }
            return (c, st.tasks)
        }
        tasks.forEach { $0.cancel() }
        cont?.resume(with: result)
    }
}

public actor DictationController {
    private let transcribers: [String: any Transcriber]
    private let formatters: [String: any Formatter]
    private let inserter: any TextInserting
    private let context: any ContextReading
    private let settings: @Sendable () -> Settings
    private let availability: @Sendable () -> ProviderAvailability
    private let history: any HistoryStoring
    private let clock: any Clock
    private let continuation: AsyncStream<DictationEvent>.Continuation

    public nonisolated let events: AsyncStream<DictationEvent>
    public private(set) var state: DictationState = .idle

    private var mode: DictationMode = .english
    private var snapshotTask: Task<ContextSnapshot?, Never>?
    /// Bumped by keyDown and cancel; a running keyUp that sees a change stops at its next await.
    private var generation = 0
    /// Whether the most recent transcribe attempt failed because its model isn't installed/verified yet.
    private var lastTranscribeModelMissing = false

    public init(
        transcribers: [String: any Transcriber],
        formatters: [String: any Formatter],
        inserter: any TextInserting,
        context: any ContextReading,
        settings: @escaping @Sendable () -> Settings,
        history: any HistoryStoring,
        clock: any Clock,
        availability: @escaping @Sendable () -> ProviderAvailability = { .legacy }
    ) {
        self.availability = availability
        self.transcribers = transcribers
        self.formatters = formatters
        self.inserter = inserter
        self.context = context
        self.settings = settings
        self.history = history
        self.clock = clock
        let (stream, continuation) = AsyncStream<DictationEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Public API

    public func keyDown(mode: DictationMode) {
        if state != .idle {
            if state != .recording {
                emit(.notice(.busy))
            }
            return
        }
        generation += 1
        self.mode = mode
        let context = self.context
        snapshotTask = Task { await context.snapshot() }
        setState(.recording)
    }

    /// The system prompt and the context part of the user message that `keyUp` will send to the local formatter,
    /// built from the same snapshot, settings and routing. Call right after `keyDown` and send it to the formatter's
    /// warm-up so the context is evaluated while the user speaks. Waits for the context snapshot, so call it from a
    /// detached task. Returns nil when not recording, superseded, or when the routed formatter is not a local one ("ollama" or "llama").
    public func prewarmRequest() async -> (system: String, userPrefix: String, formatter: String)? {
        guard state == .recording, let task = snapshotTask else { return nil }
        let gen = generation
        let mode = self.mode
        let rawSnapshot = await task.value
        guard gen == generation, state == .recording else { return nil }
        let settings = self.settings()
        let pipeline = Router.route(mode: mode, settings: settings, bundleId: rawSnapshot?.app.bundleId ?? "", availability: availability())
        guard ["ollama", "llama"].contains(pipeline.primaryFormatter) else { return nil }
        let trimmed = rawSnapshot.flatMap { ContextTrimmer.trim($0) }
        let request = Self.formatRequest(
            text: "", languageCode: nil, pipeline: pipeline, settings: settings, mode: mode, trimmed: trimmed)
        let style = ContextStyle.forFormatter(pipeline.primaryFormatter)
        let parts = PromptBuilder.userParts(request, includeContext: request.context != nil, style: style)
        return (PromptBuilder.system(mode: mode, strength: pipeline.strength, tone: pipeline.tone, contextStyle: style), parts.prefix, pipeline.primaryFormatter)
    }

    private static func formatRequest(
        text: String, languageCode: String?, pipeline: Pipeline, settings: Settings,
        mode: DictationMode, trimmed: ContextSnapshot?
    ) -> FormatRequest {
        FormatRequest(
            raw: RawTranscript(text: text, languageCode: languageCode),
            context: pipeline.sendContext ? trimmed : nil,
            dictionary: pipeline.sendContext ? settings.dictionary : [],
            tone: pipeline.tone,
            mode: mode,
            strength: pipeline.strength
        )
    }

    public func cancel() {
        generation += 1
        snapshotTask?.cancel()
        snapshotTask = nil
        if state != .idle { setState(.idle) }
    }

    public func keyUp(clip: AudioClip, charBeforeCursor: Character?) async -> DictationResult {
        guard state == .recording else { return DictationResult() }
        let gen = generation
        let mode = self.mode
        let task = snapshotTask
        snapshotTask = nil

        guard AudioMath.isUsable(clip) else {
            task?.cancel()
            return finish(gen, notice: .nothingHeard)
        }

        setState(.transcribing)
        let rawSnapshot = await task?.value
        guard gen == generation else { return DictationResult() }

        let settings = self.settings()
        let pipeline = Router.route(mode: mode, settings: settings, bundleId: rawSnapshot?.app.bundleId ?? "", availability: availability())
        var usedLocalNoticed = false

        // Transcribe, falling back to the local engine when the cloud one fails or times out.
        lastTranscribeModelMissing = false
        var transcript = await attemptTranscribe(pipeline.primaryTranscriber, clip, mode, gen)
        guard gen == generation else { return DictationResult() }
        if transcript == nil, let fallback = pipeline.fallbackTranscriber {
            emit(.notice(.usedLocal))
            usedLocalNoticed = true
            transcript = await attemptTranscribe(fallback, clip, mode, gen)
            guard gen == generation else { return DictationResult() }
        }
        guard let transcript else {
            return finish(gen, notice: lastTranscribeModelMissing ? .speechModelDownloading : .transcriptionFailed)
        }

        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return finish(gen, notice: .nothingHeard) }

        // Format.
        setState(.formatting)
        let trimmed = rawSnapshot.flatMap { ContextTrimmer.trim($0) }
        let request = Self.formatRequest(
            text: raw, languageCode: transcript.languageCode, pipeline: pipeline, settings: settings,
            mode: mode, trimmed: trimmed)
        var formatted: String?
        var formattedBy = pipeline.primaryFormatter
        if pipeline.primaryFormatter == "passthrough" {
            formatted = raw
        } else {
            formatted = await attemptFormat(pipeline.primaryFormatter, request, gen)
            guard gen == generation else { return DictationResult() }
            if formatted == nil, let fallback = pipeline.fallbackFormatter, fallback != "passthrough" {
                if !usedLocalNoticed { emit(.notice(.usedLocal)) }
                formattedBy = fallback
                formatted = await attemptFormat(fallback, request, gen)
                guard gen == generation else { return DictationResult() }
            }
            if formatted == nil { emit(.notice(.cleanupOff)) }
        }

        // Safety check, post-processing.
        var usedRaw = false
        var text = raw
        var allowedExtra = settings.dictionary
        if request.context != nil {
            if ContextStyle.forFormatter(formattedBy) == .hints {
                // Exactly what the local model was given.
                allowedExtra = PromptBuilder.hints(for: request)
            } else if let trimmed {
                allowedExtra += trimmed.screenWords
                allowedExtra.append(trimmed.beforeText)
                allowedExtra.append(trimmed.afterText)
            }
        }
        if let formatted, !PostProcessor.shouldUseRaw(raw: raw, formatted: formatted, allowedExtra: allowedExtra, mode: mode) {
            text = formatted
        } else {
            usedRaw = true
        }
        if pipeline.primaryFormatter == "passthrough" { usedRaw = true }
        text = PostProcessor.apply(text, snippets: settings.snippets, replacements: settings.replacements)
        text = PostProcessor.withLeadingSpace(text, charBeforeCursor: charBeforeCursor)

        // Insert.
        setState(.inserting)
        let outcome = await inserter.insert(text)
        guard gen == generation else { return DictationResult() }
        if outcome == .copiedOnly { emit(.notice(.copiedPressCmdV)) }

        await history.append(HistoryEntry(
            date: Date(timeIntervalSince1970: clock.now()),
            raw: raw,
            final: text,
            appBundleId: rawSnapshot?.app.bundleId ?? ""
        ))
        setState(.idle)
        return DictationResult(finalText: text, raw: raw, usedRaw: usedRaw, outcome: outcome)
    }

    // MARK: - Stages

    private static func isCloud(_ id: String) -> Bool {
        ["groq", "sarvam", "claude"].contains(id)
    }

    private func attemptTranscribe(_ id: String, _ clip: AudioClip, _ mode: DictationMode, _ gen: Int) async -> RawTranscript? {
        guard let engine = transcribers[id] else { return nil }
        if !(await engine.isReady()) {
            guard gen == generation else { return nil }
            emit(.notice(.warmingUp))
        }
        let call: @Sendable () async throws -> RawTranscript = { try await engine.transcribe(clip, mode: mode) }
        lastTranscribeModelMissing = false
        do {
            if Self.isCloud(id) {
                return try await withTimeout(3.0, clock: clock, call)
            }
            return try await call()
        } catch {
            lastTranscribeModelMissing = (error as? any ModelUnavailableError)?.isModelMissing == true
            return nil
        }
    }

    private func attemptFormat(_ id: String, _ request: FormatRequest, _ gen: Int) async -> String? {
        guard let engine = formatters[id] else { return nil }
        let words = Double(request.raw.text.split(whereSeparator: \.isWhitespace).count)
        let budget = (Self.isCloud(id) ? 3.0 : 2.0) + 0.015 * words
        do {
            return try await withTimeout(budget, clock: clock) { try await engine.format(request) }
        } catch {
            return nil
        }
    }

    // MARK: - State

    private func finish(_ gen: Int, notice: Notice) -> DictationResult {
        if gen == generation {
            emit(.notice(notice))
            setState(.idle)
        }
        return DictationResult()
    }

    private func setState(_ new: DictationState) {
        state = new
        continuation.yield(.stateChanged(new))
    }

    private func emit(_ event: DictationEvent) {
        continuation.yield(event)
    }
}
