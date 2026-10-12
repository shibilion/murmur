import Foundation

// MARK: - Transcriber

public protocol Transcriber: Sendable {
    var id: String { get }
    func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript
    /// False while the engine still has to load its model. Transcribing then waits on the engine's own `prepare()`.
    func isReady() async -> Bool
}

public extension Transcriber {
    func isReady() async -> Bool { true }
}

// MARK: - Formatter

public protocol Formatter: Sendable {
    var id: String { get }
    func format(_ req: FormatRequest) async throws -> String
}

// MARK: - Text Insertion

public protocol TextInserting: Sendable {
    func insert(_ text: String) async -> InsertOutcome
}

// MARK: - Context Reading

public protocol ContextReading: Sendable {
    func snapshot() async -> ContextSnapshot?
}

// MARK: - Clock

public protocol Clock: Sendable {
    func now() -> TimeInterval
    func sleep(_ s: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}

    public func now() -> TimeInterval {
        Date().timeIntervalSince1970
    }

    public func sleep(_ s: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }
}

// MARK: - History Storing

public protocol HistoryStoring: Sendable {
    func append(_ e: HistoryEntry) async
    func recent(_ n: Int) async -> [HistoryEntry]
    func clear() async
}
