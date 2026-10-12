import Foundation
import MurmurCore
import MurmurEngines

struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    /// Switches that take no value.
    private static let switches: Set<String> = ["context"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--"), Self.switches.contains(String(args[i].dropFirst(2))) {
                flags.insert(String(args[i].dropFirst(2)))
                i += 1
            } else if args[i].hasPrefix("--"), i + 1 < args.count {
                values[String(args[i].dropFirst(2))] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
    }

    subscript(_ key: String) -> String? { values[key] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

func fail(_ message: String, code: Int32) -> Int32 {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    return code
}

/// Walks up from the current directory to the folder holding Package.swift.
func packageRoot() -> URL? {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while true {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { return nil }
        dir = parent
    }
}

/// Reads a 16 kHz mono Int16 WAV with a 44-byte header, the format of the audio fixtures.
func loadClip(_ url: URL) throws -> AudioClip {
    let data = try Data(contentsOf: url)
    let samples: [Float] = data.dropFirst(44).withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
    }
    return AudioClip(samples: samples, sampleRate: 16000)
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// True when Ollama answers and lists the model.
func ollamaHasModel(_ model: String) async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
    var req = URLRequest(url: url)
    req.timeoutInterval = 2
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = obj["models"] as? [[String: Any]] else { return false }
    return models.contains { ($0["name"] as? String) == model }
}

/// The built-in cleanup model for bench runs: `--gguf <path>` (for example an Ollama blob, which is the same quantisation),
/// else the catalog download in the Murmur model folder.
func builtinFormatter(_ o: Options) -> LlamaFormatter {
    if let path = o["gguf"] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return LlamaFormatter(folder: url.deletingLastPathComponent(), modelFile: url.lastPathComponent)
    }
    return LlamaFormatter(folder: ModelLocations.murmurModels.appendingPathComponent("qwen3-4b-instruct-gguf"))
}
