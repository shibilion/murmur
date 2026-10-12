import Foundation
import Synchronization
@testable import MurmurCore

// MurmurCore.Formatter / Clock shadow Foundation / Swift names; spell them out where it matters.

/// A clock whose time only moves when a test calls `advance(by:)`. Sleepers suspend until then.
final class VirtualClock: MurmurCore.Clock {
    private struct Sleeper {
        var deadline: TimeInterval
        var continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var time: TimeInterval = 0
        var nextId = 0
        var sleepers: [Int: Sleeper] = [:]
        var requested: [TimeInterval] = []
    }

    private let state = Mutex(State())

    func now() -> TimeInterval { state.withLock { $0.time } }

    var requestedDurations: [TimeInterval] { state.withLock { $0.requested } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(_ s: TimeInterval) async throws {
        let id = state.withLock { st -> Int in
            st.nextId += 1
            st.requested.append(s)
            return st.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let action: Result<Void, Error>? = state.withLock { st in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if s <= 0 { return .success(()) }
                    st.sleepers[id] = Sleeper(deadline: st.time + s, continuation: cont)
                    return nil
                }
                if let action { cont.resume(with: action) }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by s: TimeInterval) {
        let due: [Sleeper] = state.withLock { st in
            st.time += s
            let ids = st.sleepers.filter { $0.value.deadline <= st.time }.map(\.key)
            return ids.compactMap { st.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Yields until at least `n` tasks are suspended in `sleep`.
    func waitForSleepers(_ n: Int) async {
        while sleeperCount < n { await Task.yield() }
    }
}

struct FakeError: Error {}

struct FakeModelMissing: ModelUnavailableError { var isModelMissing: Bool { true } }

final class FakeTranscriber: Transcriber {
    let id: String
    private let text: String?
    private let delay: TimeInterval
    private let ready: Bool
    private let clock: any MurmurCore.Clock
    private let callCount = Mutex(0)
    private let modelMissing: Bool

    /// `text == nil` makes the engine throw.
    init(id: String, text: String?, delay: TimeInterval = 0, ready: Bool = true, modelMissing: Bool = false, clock: any MurmurCore.Clock) {
        self.modelMissing = modelMissing
        self.id = id
        self.text = text
        self.delay = delay
        self.ready = ready
        self.clock = clock
    }

    var calls: Int { callCount.withLock { $0 } }

    func isReady() async -> Bool { ready }

    func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript {
        callCount.withLock { $0 += 1 }
        if delay > 0 { try await clock.sleep(delay) }
        if modelMissing { throw FakeModelMissing() }
        guard let text else { throw FakeError() }
        return RawTranscript(text: text)
    }
}

final class FakeFormatter: MurmurCore.Formatter {
    enum Behavior: Sendable {
        case echo                       // raw text plus a full stop
        case fixed(String)
        case fail
    }

    let id: String
    private let behavior: Behavior
    private let delay: TimeInterval
    private let clock: any MurmurCore.Clock
    private let seen = Mutex<[FormatRequest]>([])

    init(id: String, behavior: Behavior = .echo, delay: TimeInterval = 0, clock: any MurmurCore.Clock) {
        self.id = id
        self.behavior = behavior
        self.delay = delay
        self.clock = clock
    }

    var requests: [FormatRequest] { seen.withLock { $0 } }

    func format(_ req: FormatRequest) async throws -> String {
        seen.withLock { $0.append(req) }
        if delay > 0 { try await clock.sleep(delay) }
        switch behavior {
        case .echo: return req.raw.text + "."
        case .fixed(let s): return s
        case .fail: throw FakeError()
        }
    }
}

final class FakeInserter: TextInserting {
    private let inserted = Mutex<[String]>([])
    private let outcome: InsertOutcome

    init(outcome: InsertOutcome = .pasted) { self.outcome = outcome }

    var texts: [String] { inserted.withLock { $0 } }

    func insert(_ text: String) async -> InsertOutcome {
        inserted.withLock { $0.append(text) }
        return outcome
    }
}

struct FakeContext: ContextReading {
    var value: ContextSnapshot?
    func snapshot() async -> ContextSnapshot? { value }
}

final class FakeHistory: HistoryStoring {
    private let entries = Mutex<[HistoryEntry]>([])
    var all: [HistoryEntry] { entries.withLock { $0 } }
    func append(_ e: HistoryEntry) async { entries.withLock { $0.append(e) } }
    func recent(_ n: Int) async -> [HistoryEntry] { Array(all.suffix(n)) }
    func clear() async { entries.withLock { $0.removeAll() } }
}

/// A formatter that suspends on a continuation and ignores task cancellation until the test releases it.
final class GatedFormatter: MurmurCore.Formatter {
    let id: String
    private struct State {
        var entered = false
        var continuation: CheckedContinuation<String, Never>?
    }
    private let state = Mutex(State())

    init(id: String) { self.id = id }

    func format(_ req: FormatRequest) async throws -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            state.withLock { $0.entered = true; $0.continuation = cont }
        }
    }

    func waitUntilEntered() async {
        while !state.withLock({ $0.entered }) { await Task.yield() }
    }

    func waitUntilSuspended() async {
        var spins = 0
        while state.withLock({ $0.continuation == nil }) && spins < 100_000 {
            spins += 1
            await Task.yield()
        }
    }

    func release(with text: String) {
        let cont = state.withLock { st -> CheckedContinuation<String, Never>? in
            defer { st.continuation = nil }
            return st.continuation
        }
        cont?.resume(returning: text)
    }
}
