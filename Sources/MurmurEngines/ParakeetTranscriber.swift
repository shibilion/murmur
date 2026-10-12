import FluidAudio
import Foundation
import MurmurCore

/// English on-device engine (Parakeet v2 via FluidAudio). Ignores `mode`.
public actor ParakeetTranscriber: Transcriber {
    public nonisolated let id: String
    private var manager: AsrManager?
    private var inFlight: Task<AsrManager, Error>?

    private let folder: URL
    private let model: CatalogModel
    private let downloads: DownloadManager?

    /// Loads from `folder` only; never downloads. `downloads` (optional) receives preparing/ready state.
    public init(folder: URL, id: String = "parakeet", downloads: DownloadManager? = nil,
                model: CatalogModel = ModelCatalog.model("parakeet-v2")!) {
        self.id = id
        self.folder = folder
        self.model = model
        self.downloads = downloads
    }

    public func isReady() async -> Bool { manager != nil }

    /// Idempotent; concurrent callers share one load.
    public func prepare() async throws {
        if manager != nil { return }
        if let inFlight {
            manager = try await inFlight.value
            return
        }
        guard ModelVerification.isVerified(folder: folder, model: model) else { throw EngineError.modelMissing(model.id) }
        let folder = self.folder, modelID = model.id, downloads = self.downloads
        let task = Task<AsrManager, Error> {
            await downloads?.markPreparing(modelID)
            // loadLocal reads exactly this directory; no repo resolution, no network.
            do {
                let models = try AsrModels.loadLocal(from: folder, version: .v2)
                let mgr = AsrManager(config: .default)
                try await mgr.loadModels(models)
                await downloads?.markReady(modelID)
                return mgr
            } catch {
                await downloads?.markFailed(modelID, "Couldn't load the model. Delete it in Settings → Models and download it again.")
                throw error
            }
        }
        inFlight = task
        do {
            manager = try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }

    public func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript {
        try await prepare()
        guard let manager else { throw CancellationError() }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(clip.samples, decoderState: &state)
        return RawTranscript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), languageCode: "en")
    }
}
