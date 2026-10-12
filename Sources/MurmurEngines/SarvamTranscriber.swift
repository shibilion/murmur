import Foundation
import MurmurCore

public struct SarvamTranscriber: Transcriber {
    public let id = "sarvam"
    private let secrets: SecretStoring
    private let session: URLSession
    private let model: String

    public init(secrets: SecretStoring, session: URLSession = .shared, model: String = "saaras:v4") {
        self.secrets = secrets
        self.session = session
        self.model = model
    }

    public func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript {
        let key = try HTTP.key("sarvam", secrets)
        let request = HTTP.multipartRequest(
            URL(string: "https://api.sarvam.ai/speech-to-text")!,
            headers: ["api-subscription-key": key],
            fields: [("model", model), ("language_code", "unknown"), ("mode", "codemix")],
            wav: wavData(clip)
        )
        let obj = try HTTP.jsonObject(try await HTTP.send(request, session: session))
        guard let text = obj["transcript"] as? String else { throw EngineError.malformed }
        return RawTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                             languageCode: obj["language_code"] as? String)
    }
}
