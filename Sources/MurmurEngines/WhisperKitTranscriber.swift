import Foundation
import MurmurCore
@preconcurrency import WhisperKit

/// WhisperKit is not Sendable; it is only ever touched from inside `WhisperKitTranscriber`.
private struct KitBox: @unchecked Sendable { let kit: WhisperKit }

/// Multilingual on-device engine (Whisper large-v3-turbo via WhisperKit).
public actor WhisperKitTranscriber: Transcriber {
    public nonisolated let id: String
    private let folder: URL
    private let model: CatalogModel
    private let downloads: DownloadManager?
    private var kit: WhisperKit?
    private var inFlight: Task<KitBox, Error>?
    private var lastUse = ContinuousClock.now
    private var active = 0

    /// `folder` is the catalog install folder: model files at its top level, tokenizer in `tokenizer/`.
    public init(folder: URL, id: String = "whisperkit", downloads: DownloadManager? = nil,
                model: CatalogModel = ModelCatalog.model("whisper-large-v3-turbo")!) {
        self.id = id
        self.folder = folder
        self.model = model
        self.downloads = downloads
    }

    public func isReady() async -> Bool { kit != nil }

    /// Frees the model when it has not been used for `idle` seconds (it reloads lazily on the next `prepare`).
    /// Returns true when it unloaded something.
    @discardableResult
    public func unloadIfIdle(after idle: TimeInterval) -> Bool {
        guard kit != nil, inFlight == nil, active == 0,
              lastUse.duration(to: .now) >= .seconds(idle) else { return false }
        kit = nil
        return true
    }

    /// Idempotent; concurrent callers share one load.
    public func prepare() async throws {
        lastUse = .now
        if kit != nil { return }
        if let inFlight {
            kit = try await inFlight.value.kit
            return
        }
        guard ModelVerification.isVerified(folder: folder, model: model),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer/tokenizer.json").path)
        else { throw EngineError.modelMissing(model.id) }
        let folder = self.folder, modelID = model.id, downloads = self.downloads
        let task = Task<KitBox, Error> {
            await downloads?.markPreparing(modelID)
            // Local folders and download: false; a missing tokenizer would otherwise hit the Hub.
            do {
                let kit = try await KitBox(kit: WhisperKit(WhisperKitConfig(
                    modelFolder: folder.path,
                    tokenizerFolder: folder.appendingPathComponent("tokenizer", isDirectory: true),
                    verbose: false, prewarm: true, load: true, download: false)))
                await downloads?.markReady(modelID)
                return kit
            } catch {
                await downloads?.markFailed(modelID, "Couldn't load the model. Delete it in Settings → Models and download it again.")
                throw error
            }
        }
        inFlight = task
        do {
            kit = try await task.value.kit
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }

    public func transcribe(_ clip: AudioClip, mode: DictationMode) async throws -> RawTranscript {
        try await prepare()
        guard let kit else { throw CancellationError() }
        active += 1
        defer { active -= 1; lastUse = .now }
        let lang = mode == .indian ? "hi" : "en"
        let opts = DecodingOptions(task: .transcribe, language: lang, detectLanguage: false)
        let results = try await kit.transcribe(audioArray: clip.samples, decodeOptions: opts)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return RawTranscript(text: text, languageCode: lang)
    }
}
