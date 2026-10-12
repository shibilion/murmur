import Foundation
import MurmurEngines
import Observation

/// Checks whether the local Ollama server is reachable and has the configured model (Settings → Models, Advanced).
@MainActor
@Observable
final class OllamaSetup {
    enum State: Equatable {
        case unknown
        case unreachable
        case modelMissing
        case ready
    }

    nonisolated static let downloadURL = URL(string: "https://ollama.com/download")!
    private nonisolated static let base = URL(string: "http://127.0.0.1:11434")!

    private(set) var state: State = .unknown
    /// Reads the configured model name (Settings → Models) on each use.
    @ObservationIgnored var modelProvider: @Sendable () -> String = { "qwen3:4b-instruct" }
    /// Called on the main actor after every probe completes.
    @ObservationIgnored var onProbe: (() -> Void)?
    var model: String { modelProvider() }

    var isReachable: Bool {
        switch state {
        case .unknown, .unreachable: false
        default: true
        }
    }

    func refresh() {
        let model = self.model
        Task { [weak self] in
            let result = await Self.probe(model: model)
            guard let self else { return }
            self.state = result
            self.onProbe?()
        }
    }

    private nonisolated static func probe(model: String) async -> State {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1
        cfg.timeoutIntervalForResource = 1
        guard let (data, resp) = try? await URLSession(configuration: cfg).data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .unreachable }
        let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let names = models.compactMap { $0["name"] as? String }
        return (names.contains(model) || (!model.contains(":") && names.contains(model + ":latest"))) ? .ready : .modelMissing
    }
}
