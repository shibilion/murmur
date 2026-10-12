import Foundation
import MurmurCore

extension EngineError: ModelUnavailableError {
    public var isModelMissing: Bool { if case .modelMissing = self { true } else { false } }
}

public enum EngineError: Error, Equatable {
    case modelMissing(String)
    case missingKey(String)
    case http(Int, String)
    case timeout
    case malformed
    /// Apple Intelligence is unavailable; the payload is user-facing copy.
    case unavailable(String)
    /// The on-device model refused or a guardrail blocked the request.
    case refused
}

/// 16-bit PCM mono 16 kHz WAV, encoded in memory (never touches disk).
public func wavData(_ clip: AudioClip) -> Data {
    let sampleRate: UInt32 = 16_000
    let dataSize = UInt32(clip.samples.count * 2)
    var d = Data(capacity: 44 + Int(dataSize))
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataSize)
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); put32(16)
    put16(1); put16(1); put32(sampleRate); put32(sampleRate * 2); put16(2); put16(16)
    d.append(contentsOf: Array("data".utf8)); put32(dataSize)
    for s in clip.samples {
        let c = max(-1, min(1, s))
        put16(UInt16(bitPattern: Int16(c * 32767)))
    }
    return d
}

enum HTTP {
    static func key(_ name: String, _ secrets: SecretStoring) throws -> String {
        guard let k = secrets.get(name), !k.isEmpty else { throw EngineError.missingKey(name) }
        return k
    }

    /// Sends the request; maps transport errors and non-2xx to `EngineError.http`.
    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as URLError {
            if e.code == .timedOut { throw EngineError.timeout }
            throw EngineError.http(0, e.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw EngineError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw EngineError.http(http.statusCode, String(body.prefix(200)))
        }
        return data
    }

    static func jsonRequest(_ url: URL, body: [String: Any], headers: [String: String] = [:]) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func multipartRequest(_ url: URL, headers: [String: String], fields: [(String, String)], wav: Data) -> URLRequest {
        let boundary = "murmur-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        return r
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EngineError.malformed }
        return o
    }
}
