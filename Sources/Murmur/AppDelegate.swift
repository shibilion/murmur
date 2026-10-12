import AppKit
import AVFoundation
import Combine
import MurmurCore
import MurmurEngines
import Synchronization

/// Thread-safe cache the controller reads from its own executor.
final class SettingsBox: @unchecked Sendable {
    private let lock = Mutex<Settings>(Settings())
    var value: Settings {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Thread-safe cache of which cleanup providers can run now; the controller reads it from its own executor.
final class AvailabilityBox: @unchecked Sendable {
    private let lock = Mutex<ProviderAvailability>(.legacy)
    var value: ProviderAvailability {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Thread-safe cache of which speech models can run now: (parakeet, whisper).
final class SpeechReadyBox: @unchecked Sendable {
    private let lock = Mutex<(parakeet: Bool, whisper: Bool)>((false, false))
    var value: (parakeet: Bool, whisper: Bool) {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore(directory: SettingsStore.defaultDirectory())
    private let settingsBox = SettingsBox()
    private let history: FileHistoryStore
    private let secrets = KeychainStore()

    private let ollama: OllamaFormatter
    private let llama: LlamaFormatter
    private let availabilityBox = AvailabilityBox()
    private let speechReady = SpeechReadyBox()
    private var statesObserver: AnyCancellable?
    private var llamaLoadRequested = false
    private var ollamaProbeTimer: Timer?
    private var idleTimer: Timer?
    private static let llamaID = "qwen3-4b-instruct-gguf"
    private let modelRoot = ModelLocations.murmurModels
    private let models: DownloadManager
    private let parakeet: ParakeetTranscriber
    private let whisper: WhisperKitTranscriber

    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private let ax = AXContextReader()
    private let overlay = OverlayPanel()
    private var statusMenu: StatusMenu?
    private var controller: DictationController?

    private var isRecording = false
    private var handsFree = false
    private var hotkeyEvents: AsyncStream<HotkeyEvent>.Continuation?
    private var permissionTimer: Timer?

    private let ollamaSetup = OllamaSetup()
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: AboutWindowController?
    private var getStartedWindow: GetStartedWindowController?

    override init() {
        history = FileHistoryStore(directory: SettingsStore.defaultDirectory())
        let box = settingsBox
        ollama = OllamaFormatter(model: { box.value.ollamaModel })
        let root = modelRoot
        let downloads = DownloadManager(root: root, freeSpace: {
            let v = try? FileManager.default.homeDirectoryForCurrentUser
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return v?.volumeAvailableCapacityForImportantUsage ?? 0
        })
        models = downloads
        llama = LlamaFormatter(folder: downloads.folder(for: Self.llamaID), downloads: downloads)
        parakeet = ParakeetTranscriber(folder: downloads.folder(for: "parakeet-v2"), downloads: downloads)
        whisper = WhisperKitTranscriber(folder: downloads.folder(for: "whisper-large-v3-turbo"), downloads: downloads)
        super.init()
        settingsBox.value = (try? settingsStore.load()) ?? Settings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let box = settingsBox
        let availability = availabilityBox
        ollamaSetup.modelProvider = { box.value.ollamaModel }
        let settingsNow = box.value
        let speech = speechReady
        let controller = DictationController(
            transcribers: [
                "parakeet": parakeet,
                "whisperkit": whisper,
                "groq": GroqTranscriber(secrets: secrets),
                "sarvam": SarvamTranscriber(secrets: secrets, model: settingsNow.sarvamModel),
            ],
            formatters: [
                "ollama": ollama,
                "llama": llama,
                "apple": AppleIntelligenceFormatter(),
                "claude": ClaudeFormatter(secrets: secrets),
                "passthrough": PassthroughFormatter(),
            ],
            inserter: PasteboardInserter(),
            context: ax,
            // Routing sees the English engine that can actually run; the stored preference is untouched.
            settings: {
                var s = box.value
                let r = speech.value
                s.englishEngine = EnginePicker.effectiveEnglish(
                    preferred: s.englishEngine, parakeetReady: r.parakeet, whisperReady: r.whisper)
                return s
            },
            history: history,
            clock: SystemClock(),
            availability: { availability.value }
        )
        self.controller = controller

        let menu = StatusMenu(
            settings: { box.value },
            updateSettings: { [weak self] mutate in self?.updateSettings(mutate) },
            history: history,
            inserter: PasteboardInserter()
        )
        statusMenu = menu

        // Settings and Get started windows.
        let store = settingsStore
        let model = SettingsModel(initial: box.value) { try? store.save($0) }
        model.onChange = { [weak self] new in
            self?.settingsBox.value = new
            self?.syncLlama()
            self?.statusMenu?.checkPermissions()
        }
        settingsModel = model
        let settingsWindow = SettingsWindowController(
            model: model, models: self.models, ollama: ollamaSetup, secrets: secrets, history: history)
        self.settingsWindow = settingsWindow
        let aboutWindow = AboutWindowController()
        self.aboutWindow = aboutWindow
        settingsWindow.onOpenAbout = { [weak aboutWindow] in aboutWindow?.show() }
        let getStarted = GetStartedWindowController(models: self.models, settings: model, ollama: ollamaSetup)
        getStarted.model.onInputMonitoringGranted = { [weak self] in self?.startHotkeysIfPossible() }
        getStartedWindow = getStarted
        menu.onOpenSettings = { [weak self, weak settingsWindow] in
            guard let self, let settingsWindow else { return }
            settingsWindow.show(current: self.settingsBox.value)
        }
        menu.onOpenSetup = { [weak getStarted] in getStarted?.show() }
        menu.onOpenAbout = { [weak aboutWindow] in aboutWindow?.show() }

        recorder.onLevel = { [weak self] level in self?.overlay.setLevel(level) }

        // Controller events -> overlay and status item.
        Task { [weak self] in
            for await event in controller.events {
                guard let self else { return }
                self.overlay.handle(event)
                if case .stateChanged(let state) = event {
                    self.statusMenu?.setRecording(state == .recording)
                    if state == .idle { self.statusMenu?.refreshHistory() }
                }
            }
        }

        // Hotkey events are processed strictly in order; only the long pipeline is detached.
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()
        hotkeyEvents = continuation
        hotkeys.onEvent = { continuation.yield($0) }
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }

        startHotkeysIfPossible()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startHotkeysIfPossible() }
        }

        Task { [weak self] in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                if await AVCaptureDevice.requestAccess(for: .audio) { try? self?.recorder.prepare() }
                self?.statusMenu?.checkPermissions()
            case .authorized:
                try? self?.recorder.prepare()
            default:
                break
            }
        }

        // Models and Ollama warm-up in the background.
        let models = self.models
        // Move any pre-0.2 models into the new layout (off the main thread) before engines prepare.
        let root = modelRoot
        let parakeet = self.parakeet
        // Models about to be moved show as "Checking download…" until the migration finishes.
        // Only the two App Support paths are probed here; defaultLegacy() (which may touch ~/Documents) runs off-main below.
        let support = ModelLocations.applicationSupport
        models.beginExternalVerification(ModelCatalog.all.filter { m in
            guard m.kind == .speech else { return false }
            let probe: URL = m.id == "parakeet-v2"
                ? support.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v2", isDirectory: true)
                : ModelLocations.murmurModels.appendingPathComponent(
                    "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
            return FileManager.default.fileExists(atPath: probe.path)
        }.map(\.id))
        // Decided now, from the current states; the cards update live while the migration runs.
        if GetStartedWindowController.shouldShowAtLaunch(models: models) { getStarted.show() }
        Task {
            _ = await Task.detached(priority: .utility) { await ModelMigration.run(root: root, legacy: ModelMigration.defaultLegacy()) }.value
            models.refresh()
            try? await parakeet.prepare()
        }
        prewarmWhisper()
        observeProviderAvailability()
        warmOllamaModel()
        startIdleUnloadTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsModel?.flush()
        hotkeys.stop()
    }

    // MARK: - Settings

    private func updateSettings(_ mutate: (inout Settings) -> Void) {
        var s = settingsBox.value
        mutate(&s)
        settingsBox.value = s
        try? settingsStore.save(s)
        settingsModel?.refresh(s)
    }

    // MARK: - Hotkeys

    private func startHotkeysIfPossible() {
        // Retries until Input Monitoring is granted; start() is a no-op once the tap exists.
        hotkeys.start()
    }

    private func handle(_ event: HotkeyEvent) async {
        guard let controller else { return }
        let sounds = settingsBox.value.soundsEnabled
        switch event {
        case .start(let mode):
            await begin(mode: mode, handsFree: false, controller: controller)
        case .toggleHandsFree(let mode):
            // The preceding quick-tap cancel already stopped the first recording; start fresh in hands-free.
            await begin(mode: mode, handsFree: true, controller: controller)
        case .stop:
            guard isRecording else { return }
            isRecording = false
            handsFree = false
            let clip = await recorder.stop()
            let ch = await ax.charBeforeCursor()
            Sounds.playStop(enabled: sounds)
            // Detached so the next key press is not queued behind transcription; the controller reports busy.
            Task { _ = await controller.keyUp(clip: clip, charBeforeCursor: ch) }
        case .cancel, .abortedAsModifier:
            // Only cancel what we started, so a stray quick-tap never kills a dictation still being processed.
            guard isRecording else { return }
            isRecording = false
            handsFree = false
            _ = await recorder.stop()
            await controller.cancel()
        }
    }

    private func begin(mode: DictationMode, handsFree: Bool, controller: DictationController) async {
        if await controller.state != .idle {
            // Previous dictation still finishing: let the controller emit its "busy" notice and do not record.
            await controller.keyDown(mode: mode)
            return
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .denied || mic == .restricted {
            overlay.showMessage(OverlayCopy.micOff)
            return
        }
        do {
            try recorder.start()
        } catch {
            overlay.showMessage(OverlayCopy.micUnavailable)
            return
        }
        isRecording = true
        self.handsFree = handsFree
        overlay.setMode(mode, handsFree: handsFree)
        await controller.keyDown(mode: mode)
        Sounds.playStart(enabled: settingsBox.value.soundsEnabled)
        prewarmLocalFormatter(controller: controller)
        if mode == .indian { let whisper = self.whisper; Task { try? await whisper.prepare() } }
    }

    /// About 20 s after launch, once Parakeet is ready, load Whisper so the first Hindi dictation is not
    /// stuck compiling for the Neural Engine. Never downloads: only runs if the files are already on disk.
    private func prewarmWhisper() {
        let models = self.models
        let box = settingsBox
        let whisper = self.whisper
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(20))
            for _ in 0..<24 {
                if models.states["parakeet-v2"] == .ready { break }
                try? await Task.sleep(for: .seconds(5))
            }
            guard models.states["parakeet-v2"] == .ready,
                  models.states["whisper-large-v3-turbo"] == .ready,
                  box.value.prewarmIndianModel else { return }
            try? await whisper.prepare()
        }
    }

    /// At launch: load the model into memory (system prompt only, no dictation context yet).
    private func warmOllamaModel() {
        let s = settingsBox.value
        guard Router.route(mode: .english, settings: s, bundleId: "", availability: availabilityBox.value).primaryFormatter == "ollama" else { return }
        let system = PromptBuilder.system(mode: .english, strength: s.strength, tone: .neutral, contextStyle: .hints)
        let ollama = self.ollama
        Task { await ollama.warm(system: system, userPrefix: "") }
    }

    /// At key-down: once the context snapshot is trimmed, prefill system prompt plus context on the model while the
    /// user speaks. The controller applies the same routing and trimming that key-up will use.
    private func prewarmLocalFormatter(controller: DictationController) {
        let ollama = self.ollama, llama = self.llama
        Task {
            guard let p = await controller.prewarmRequest() else { return }
            if p.formatter == "llama" {
                await llama.warm(system: p.system, userPrefix: p.userPrefix)
            } else {
                await ollama.warm(system: p.system, userPrefix: p.userPrefix)
            }
        }
    }

    // MARK: - Built-in model

    /// Keeps `availabilityBox` current from the download states and the Ollama probe, and loads the built-in model in
    /// the background as soon as it is on disk (at launch, or when its download completes).
    private func observeProviderAvailability() {
        statesObserver = models.$states.sink { [weak self] states in
            MainActor.assumeIsolated { self?.statesChanged(states) }
        }
        ollamaSetup.onProbe = { [weak self] in
            guard let self else { return }
            self.updateAvailability(self.models.states)
            self.syncLlama()
        }
        ollamaSetup.refresh()
        ollamaProbeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ollamaSetup.refresh() }
        }
    }

    private func statesChanged(_ states: [String: DownloadState]) {
        updateAvailability(states)
        syncLlama()
    }

    /// Qwen3 is resident only while it is the effective local formatter: loaded (and prewarmed) when it becomes
    /// effective, unloaded when the provider changes to something else.
    func syncLlama() {
        let state = models.states[Self.llamaID]
        let effective = ProviderResolver.localFormatter(settingsBox.value.cleanupProvider, availabilityBox.value)
        let llama = self.llama
        if state != .ready && state != .preparing { llamaLoadRequested = false }
        if effective != "llama" {
            guard llamaLoadRequested else { return }
            llamaLoadRequested = false
            Task(priority: .utility) { await llama.unload() }
            return
        }
        guard state == .ready, !llamaLoadRequested else { return }
        llamaLoadRequested = true
        let s = settingsBox.value
        Task(priority: .utility) {
            do { try await llama.prepare() } catch { return }
            let system = PromptBuilder.system(mode: .english, strength: s.strength, tone: .neutral, contextStyle: .hints)
            await llama.warm(system: system, userPrefix: "")
        }
    }

    private func updateAvailability(_ states: [String: DownloadState]) {
        func usable(_ id: String) -> Bool { states[id] == .ready || states[id] == .preparing }
        speechReady.value = (usable("parakeet-v2"), usable("whisper-large-v3-turbo"))
        let llamaState = states[Self.llamaID]
        availabilityBox.value = ProviderAvailability(
            // Preparing means the files are verified and the model is being loaded (or reloaded).
            builtInReady: llamaState == .ready || llamaState == .preparing,
            appleAvailable: AppleIntelligenceFormatter.isUsable,
            ollamaReachable: ollamaSetup.state == .ready)
    }

    // MARK: - Memory

    /// Whisper is the biggest resident model and rarely used; free it after 10 minutes unused. It reloads on demand.
    private func startIdleUnloadTimer() {
        let whisper = self.whisper
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task(priority: .utility) { await whisper.unloadIfIdle(after: 600) }
        }
    }
}
