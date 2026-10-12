import Foundation
import MurmurCore

/// English cloud route only.
public struct GroqTranscriber: Transcriber {
    public let id = "groq"
    private let secrets: SecretStoring
    private let session: URLSession

    public init(secrets: SecretStoring, session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    public func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript {
        let key = try HTTP.key("groq", secrets)
        let request = HTTP.multipartRequest(
            URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
            headers: ["Authorization": "Bearer \(key)"],
            fields: [("model", "whisper-large-v3-turbo"), ("language", "en"), ("response_format", "json")],
            wav: wavData(clip)
        )
        let obj = try HTTP.jsonObject(try await HTTP.send(request, session: session))
        guard let text = obj["text"] as? String else { throw EngineError.malformed }
        return RawTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), languageCode: "en")
    }
}
