import Foundation
import MurmurCore

public struct ClaudeFormatter: MurmurCore.Formatter {
    public let id = "claude"
    private let secrets: SecretStoring
    private let session: URLSession

    public init(secrets: SecretStoring, session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    public func format(_ req: FormatRequest) async throws -> String {
        let key = try HTTP.key("anthropic", secrets)
        let system = PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone)
        let user = PromptBuilder.user(req, includeContext: req.context != nil)
        let request = try HTTP.jsonRequest(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            body: [
                "model": "claude-haiku-4-5",
                "max_tokens": 2048,
                "temperature": 0,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ],
            headers: ["x-api-key": key, "anthropic-version": "2023-06-01"]
        )
        let obj = try HTTP.jsonObject(try await HTTP.send(request, session: session))
        guard let items = obj["content"] as? [[String: Any]],
              let text = items.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw EngineError.malformed }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
