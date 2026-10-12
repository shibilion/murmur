import Foundation
import MurmurCore

public struct OllamaFormatter: MurmurCore.Formatter {
    public let id = "ollama"
    private let baseURL: URL
    private let model: @Sendable () -> String
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: @escaping @Sendable () -> String = { "qwen3:4b-instruct" }, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    public func format(_ req: FormatRequest) async throws -> String {
        let system = PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone, contextStyle: .hints)
        let user = PromptBuilder.user(req, includeContext: req.context != nil, style: .hints)
        let data = try await HTTP.send(try request(system: system, user: user, rawWordCount: Self.wordCount(req.raw.text)), session: session)
        let obj = try HTTP.jsonObject(data)
        guard let content = (obj["message"] as? [String: Any])?["content"] as? String else { throw EngineError.malformed }
        return Self.stripThink(content)
    }

    /// Prefills system prompt plus the context part of the user message while the user is still speaking, so the
    /// real request only evaluates the transcript tail (llama.cpp reuses the common prompt prefix).
    /// Generates a single token; the response is ignored. Swallows all errors.
    public func warm(system: String, userPrefix: String) async {
        guard let r = try? request(system: system, user: userPrefix, numPredict: 1) else { return }
        _ = try? await HTTP.send(r, session: session)
    }

    private func request(system: String, user: String, rawWordCount: Int = 0, numPredict: Int? = nil) throws -> URLRequest {
        try HTTP.jsonRequest(baseURL.appendingPathComponent("api/chat"), body: [
            "model": model(),
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
            "think": false,
            "keep_alive": "30m",
            "options": ["temperature": 0, "num_predict": numPredict ?? Self.tokenCap(forRawWordCount: rawWordCount)],
        ])
    }

    /// Generation cap: generous for the cleaned text, tight enough to stop runaway output.
    static func tokenCap(forRawWordCount n: Int) -> Int { max(32, 2 * n + 16) }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).count
    }

    static func stripThink(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<think>"), let end = t.range(of: "</think>") {
            t = String(t[end.upperBound...])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
