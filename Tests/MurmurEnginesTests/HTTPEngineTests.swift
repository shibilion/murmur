import Foundation
import Synchronization
import Testing
import MurmurCore
@testable import MurmurEngines

struct RecordedRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
    func json() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Canned: Sendable { var status: Int; var body: Data; var error: URLError? }
    private struct State { var canned = Canned(status: 200, body: Data(), error: nil); var requests: [RecordedRequest] = [] }
    private static let state = Mutex(State())

    static func reset(status: Int = 200, body: String = "", error: URLError? = nil) {
        state.withLock { $0 = State(canned: Canned(status: status, body: Data(body.utf8), error: error)) }
    }
    static var requests: [RecordedRequest] { state.withLock { $0.requests } }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let rec = RecordedRequest(url: request.url!, method: request.httpMethod ?? "GET",
                                  headers: request.allHTTPHeaderFields ?? [:], body: body)
        let canned = Self.state.withLock { s -> Canned in s.requests.append(rec); return s.canned }
        if let e = canned.error { client?.urlProtocol(self, didFailWithError: e); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func formatReq() -> FormatRequest {
    FormatRequest(raw: RawTranscript(text: "um hello world"))
}
private func clip() -> AudioClip { AudioClip(samples: [0, 0.5, -0.5, 2, -2], sampleRate: 16_000) }
private func bodyString(_ r: RecordedRequest) -> String { String(decoding: r.body, as: UTF8.self) }

@Suite(.serialized)
struct HTTPEngineTests {
    // MARK: wav
    @Test func wavHeaderIsValid() {
        let d = wavData(clip())
        #expect(d.count == 44 + 5 * 2)
        #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
        func u32(_ o: Int) -> UInt32 { d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u16(_ o: Int) -> UInt16 { d.subdata(in: o..<o + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        #expect(u32(4) == UInt32(d.count - 8))
        #expect(u16(20) == 1)
        #expect(u16(22) == 1)
        #expect(u32(24) == 16_000)
        #expect(u32(28) == 32_000)
        #expect(u16(34) == 16)
        #expect(u32(40) == 10)
        // clamped samples: 2 -> 32767, -2 -> -32767
        let s3 = Int16(bitPattern: u16(44 + 6)), s4 = Int16(bitPattern: u16(44 + 8))
        #expect(s3 == 32767)
        #expect(s4 == -32767)
    }

    // MARK: ollama
    @Test func ollamaRequestAndParse() async throws {
        StubURLProtocol.reset(body: #"{"message":{"role":"assistant","content":"  Hello world.  "}}"#)
        let f = OllamaFormatter(session: StubURLProtocol.session())
        let out = try await f.format(formatReq())
        #expect(out == "Hello world.")
        let r = try #require(StubURLProtocol.requests.first)
        #expect(r.url.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(r.method == "POST")
        let j = try r.json()
        #expect(j["model"] as? String == "qwen3:4b-instruct")
        #expect(j["stream"] as? Bool == false)
        #expect(j["think"] as? Bool == false)
        #expect(j["keep_alive"] as? String == "30m")
        let options = j["options"] as? [String: Any]
        #expect(options?["temperature"] as? Double == 0)
        #expect(options?["num_predict"] as? Int == 32)
        let msgs = try #require(j["messages"] as? [[String: String]])
        #expect(msgs.map { $0["role"] } == ["system", "user"])
        let req = formatReq()
        #expect(msgs[0]["content"] == PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone, contextStyle: .hints))
        #expect(msgs[1]["content"] == PromptBuilder.user(req, includeContext: false, style: .hints))
    }

    @Test func tokenCapFloor() {
        #expect(OllamaFormatter.tokenCap(forRawWordCount: 0) == 32)
        #expect(OllamaFormatter.tokenCap(forRawWordCount: 5) == 32)
    }

    @Test func tokenCapScales() {
        #expect(OllamaFormatter.tokenCap(forRawWordCount: 100) == 216)
    }

    @Test func ollamaThinkTagsStripped() async throws {
        StubURLProtocol.reset(body: #"{"message":{"content":"<think>\nreasoning\n</think>\n\nClean text."}}"#)
        let out = try await OllamaFormatter(session: StubURLProtocol.session()).format(formatReq())
        #expect(out == "Clean text.")
    }

    @Test func ollama401() async throws {
        StubURLProtocol.reset(status: 401, body: "nope")
        await #expect {
            try await OllamaFormatter(session: StubURLProtocol.session()).format(formatReq())
        } throws: { error in
            guard case EngineError.http(401, _) = error else { return false }
            return true
        }
    }

    @Test func ollamaNetworkErrorMapsToHTTP0() async throws {
        StubURLProtocol.reset(error: URLError(.cannotConnectToHost))
        await #expect {
            try await OllamaFormatter(session: StubURLProtocol.session()).format(formatReq())
        } throws: { error in
            guard case EngineError.http(0, _) = error else { return false }
            return true
        }
    }

    @Test func ollamaWarmSendsContextPrefixOneTokenAndSwallowsErrors() async throws {
        StubURLProtocol.reset(status: 500, body: "boom")
        await OllamaFormatter(session: StubURLProtocol.session()).warm(system: "SYS", userPrefix: "<app>ctx</app>\n\n")
        let r = try #require(StubURLProtocol.requests.first)
        let j = try r.json()
        let msgs = try #require(j["messages"] as? [[String: String]])
        #expect(msgs[0]["role"] == "system")
        #expect(msgs[0]["content"] == "SYS")
        #expect(msgs[1]["role"] == "user")
        #expect(msgs[1]["content"] == "<app>ctx</app>\n\n")
        #expect((j["options"] as? [String: Any])?["num_predict"] as? Int == 1)
    }

    // MARK: claude
    @Test func claudeRequestAndParse() async throws {
        StubURLProtocol.reset(body: #"{"content":[{"type":"thinking","text":"x"},{"type":"text","text":" Hi there. "}]}"#)
        let secrets = InMemorySecretStore(); secrets.set("anthropic", "sk-test")
        let out = try await ClaudeFormatter(secrets: secrets, session: StubURLProtocol.session()).format(formatReq())
        #expect(out == "Hi there.")
        let r = try #require(StubURLProtocol.requests.first)
        #expect(r.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.header("x-api-key") == "sk-test")
        #expect(r.header("anthropic-version") == "2023-06-01")
        #expect(r.header("content-type") == "application/json")
        let j = try r.json()
        #expect(j["model"] as? String == "claude-haiku-4-5")
        #expect(j["max_tokens"] as? Int == 2048)
        #expect(j["temperature"] as? Double == 0)
        let req = formatReq()
        #expect(j["system"] as? String == PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone))
        let msgs = try #require(j["messages"] as? [[String: String]])
        #expect(msgs.count == 1)
        #expect(msgs[0]["role"] == "user")
        #expect(msgs[0]["content"] == PromptBuilder.user(req, includeContext: false))
    }

    @Test func claude401() async throws {
        StubURLProtocol.reset(status: 401, body: "bad key")
        let secrets = InMemorySecretStore(); secrets.set("anthropic", "sk-secret")
        await #expect {
            try await ClaudeFormatter(secrets: secrets, session: StubURLProtocol.session()).format(formatReq())
        } throws: { error in
            guard case EngineError.http(401, let msg) = error else { return false }
            return !msg.contains("sk-secret")
        }
    }

    @Test func claudeMissingKeyThrowsBeforeRequest() async throws {
        StubURLProtocol.reset()
        let secrets = InMemorySecretStore(); secrets.set("anthropic", "")
        await #expect {
            try await ClaudeFormatter(secrets: secrets, session: StubURLProtocol.session()).format(formatReq())
        } throws: { error in
            guard case EngineError.missingKey("anthropic") = error else { return false }
            return true
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    // MARK: groq
    @Test func groqRequestAndParse() async throws {
        StubURLProtocol.reset(body: #"{"text":" hello there "}"#)
        let secrets = InMemorySecretStore(); secrets.set("groq", "gsk-test")
        let out = try await GroqTranscriber(secrets: secrets, session: StubURLProtocol.session())
            .transcribe(clip(), mode: .english)
        #expect(out.text == "hello there")
        let r = try #require(StubURLProtocol.requests.first)
        #expect(r.url.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(r.header("authorization") == "Bearer gsk-test")
        #expect(r.header("content-type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let b = bodyString(r)
        #expect(b.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
        #expect(b.contains("name=\"language\"\r\n\r\nen"))
        #expect(b.contains("name=\"response_format\"\r\n\r\njson"))
        #expect(b.contains("name=\"file\"; filename=\"audio.wav\""))
        #expect(b.contains("RIFF"))
    }

    @Test func groq401() async throws {
        StubURLProtocol.reset(status: 401, body: "unauthorized")
        let secrets = InMemorySecretStore(); secrets.set("groq", "k")
        await #expect {
            try await GroqTranscriber(secrets: secrets, session: StubURLProtocol.session()).transcribe(clip(), mode: .english)
        } throws: { error in
            guard case EngineError.http(401, _) = error else { return false }
            return true
        }
    }

    @Test func groqMissingKeyThrowsBeforeRequest() async throws {
        StubURLProtocol.reset()
        await #expect {
            try await GroqTranscriber(secrets: InMemorySecretStore(), session: StubURLProtocol.session())
                .transcribe(clip(), mode: .english)
        } throws: { error in
            guard case EngineError.missingKey("groq") = error else { return false }
            return true
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    // MARK: sarvam
    @Test func sarvamRequestAndParse() async throws {
        StubURLProtocol.reset(body: #"{"transcript":"namaste duniya","language_code":"hi-IN","language_probability":0.9}"#)
        let secrets = InMemorySecretStore(); secrets.set("sarvam", "sv-test")
        let out = try await SarvamTranscriber(secrets: secrets, session: StubURLProtocol.session(), model: "saaras:v4")
            .transcribe(clip(), mode: .indian)
        #expect(out.text == "namaste duniya")
        #expect(out.languageCode == "hi-IN")
        let r = try #require(StubURLProtocol.requests.first)
        #expect(r.url.absoluteString == "https://api.sarvam.ai/speech-to-text")
        #expect(r.header("api-subscription-key") == "sv-test")
        #expect(r.header("authorization") == nil)
        let b = bodyString(r)
        #expect(b.contains("name=\"model\"\r\n\r\nsaaras:v4"))
        #expect(b.contains("name=\"language_code\"\r\n\r\nunknown"))
        #expect(b.contains("name=\"mode\"\r\n\r\ncodemix"))
        #expect(b.contains("name=\"file\"; filename=\"audio.wav\""))
    }

    @Test func sarvamModelComesFromParameter() async throws {
        StubURLProtocol.reset(body: #"{"transcript":"x"}"#)
        let secrets = InMemorySecretStore(); secrets.set("sarvam", "k")
        let out = try await SarvamTranscriber(secrets: secrets, session: StubURLProtocol.session(), model: "saaras:v3")
            .transcribe(clip(), mode: .indian)
        #expect(out.languageCode == nil)
        #expect(bodyString(try #require(StubURLProtocol.requests.first)).contains("name=\"model\"\r\n\r\nsaaras:v3"))
    }

    @Test func sarvam401() async throws {
        StubURLProtocol.reset(status: 401, body: "no")
        let secrets = InMemorySecretStore(); secrets.set("sarvam", "k")
        await #expect {
            try await SarvamTranscriber(secrets: secrets, session: StubURLProtocol.session()).transcribe(clip(), mode: .indian)
        } throws: { error in
            guard case EngineError.http(401, _) = error else { return false }
            return true
        }
    }

    @Test func sarvamMissingKeyThrowsBeforeRequest() async throws {
        StubURLProtocol.reset()
        await #expect {
            try await SarvamTranscriber(secrets: InMemorySecretStore(), session: StubURLProtocol.session())
                .transcribe(clip(), mode: .indian)
        } throws: { error in
            guard case EngineError.missingKey("sarvam") = error else { return false }
            return true
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func settingsSarvamModelDefaultsAndDecodes() throws {
        #expect(Settings().sarvamModel == "saaras:v4")
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(s.sarvamModel == "saaras:v4")
        let s2 = try JSONDecoder().decode(Settings.self, from: Data(#"{"sarvamModel":"saaras:v3"}"#.utf8))
        #expect(s2.sarvamModel == "saaras:v3")
    }
}
