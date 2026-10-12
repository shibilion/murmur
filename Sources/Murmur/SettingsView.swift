import AppKit
import MurmurCore
import MurmurEngines
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case models = "Models"
    case cloud = "Cloud"
    case rules = "Per-app rules"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case history = "History"
    case privacy = "Privacy"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .cloud: "cloud"
        case .rules: "app.badge"
        case .dictionary: "character.book.closed"
        case .snippets: "text.insert"
        case .history: "clock"
        case .privacy: "lock"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @ObservedObject var models: DownloadManager
    let ollama: OllamaSetup
    let secrets: any SecretStoring
    let history: any HistoryStoring
    var onOpenAbout: (() -> Void)?

    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralSection(model: model, onOpenAbout: onOpenAbout)
                case .models: ModelsSection(model: model, models: models, ollama: ollama)
                case .cloud: CloudSection(model: model, secrets: secrets)
                case .rules: RulesSection(model: model)
                case .dictionary: DictionarySection(model: model)
                case .snippets: SnippetsSection(model: model)
                case .history: HistorySection(history: history)
                case .privacy: PrivacySection(model: model)
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .general).rawValue)
        }
        .frame(minWidth: 700, minHeight: 460)
    }
}

// MARK: - General

enum SettingsCopy {
    static let sarvamNote = "Changes to the Sarvam model apply after relaunch."
    static let cloudSent = "Speech: audio of each dictation goes to Groq (English) or Sarvam (Indian languages). Cleanup: the transcript — plus app name, nearby text and on-screen words unless you turn that off in Privacy — goes to Anthropic."
    static let privacyStatic = "Audio is never saved to disk. Password fields are never read. Murmur sends no analytics."
}

struct GeneralSection: View {
    @Bindable var model: SettingsModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    var onOpenAbout: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Button("About Murmur") { onOpenAbout?() }
            }
            Section("Hotkeys") {
                LabeledContent("Dictate (English)", value: "Hold Fn")
                LabeledContent("Dictate (Indian languages)", value: "Hold Fn + Shift")
                LabeledContent("Hands-free", value: "Double-tap Fn")
                LabeledContent("Cancel", value: "Esc")
            }
            Section {
                Picker("English engine", selection: $model.settings.englishEngine) {
                    Text("Parakeet").tag("parakeet")
                    Text("Whisper").tag("whisperkit")
                }
                Toggle("Play start and stop sounds", isOn: $model.settings.soundsEnabled)
                Toggle("Prepare Indian-language model in the background", isOn: $model.settings.prewarmIndianModel)
                LabeledContent("Hinglish script", value: "Roman")
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        loginError = LoginItem.set(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                if LoginItem.needsApproval {
                    Text("Approve Murmur in System Settings > General > Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}

// MARK: - Models

enum ModelsCopy {
    static let ollamaNote = "Use a non-thinking (instruct) model."
}

struct ModelsSection: View {
    @Bindable var model: SettingsModel
    @ObservedObject var models: DownloadManager
    let ollama: OllamaSetup

    private var availability: ProviderAvailability {
        let q = models.states[ModelsSection.qwenID]
        return ProviderAvailability(
            builtInReady: q == .ready || q == .preparing,
            appleAvailable: AppleIntelligenceFormatter.isUsable,
            ollamaReachable: ollama.isReachable)
    }

    private static let qwenID = "qwen3-4b-instruct-gguf"

    var body: some View {
        Form {
            Section("Speech") {
                ForEach(ModelCatalog.all.filter { $0.kind == .speech }) { m in
                    ModelCardView(model: m, state: models.states[m.id], selected: false, selectable: false,
                                  caption: m.id == "whisper-large-v3-turbo" ? GetStartedCopy.whisperCaption : nil) { b in
                        ModelCardActions.perform(b, id: m.id, models: models) {}
                    } onDelete: { ModelCardActions.confirmDelete(m, models: models) }
                }
            }
            Section("Cleanup") {
                if let q = ModelCatalog.model(Self.qwenID) {
                    ModelCardView(model: q, state: models.states[q.id],
                                  selected: model.settings.cleanupProvider.effective(availability) == .builtIn) { b in
                        ModelCardActions.perform(b, id: q.id, models: models) { model.settings.cleanupProvider = .builtIn }
                    } onDelete: { ModelCardActions.confirmDelete(q, models: models) }
                }
                Picker("Cleanup", selection: $model.settings.cleanupProvider) {
                    Text("Automatic").tag(CleanupProvider.auto)
                    Text("Built-in Qwen3").tag(CleanupProvider.builtIn)
                    if AppleIntelligenceFormatter.isCompiledIn {
                        Text("Apple Intelligence").tag(CleanupProvider.appleIntelligence)
                    }
                    Text("Ollama").tag(CleanupProvider.ollama)
                    Text("Cloud").tag(CleanupProvider.cloud)
                    Text("None").tag(CleanupProvider.none)
                }
                if AppleIntelligenceFormatter.isCompiledIn, let reason = AppleIntelligenceFormatter.availability().message {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Advanced: Ollama") {
                TextField("Ollama model", text: $model.settings.ollamaModel)
                    .onSubmit { ollama.refresh() }
                Text(ModelsCopy.ollamaNote).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Ollama") {
                    HStack {
                        Text(ollamaText)
                        if ollama.state == .unreachable {
                            Button("Get Ollama") { NSWorkspace.shared.open(OllamaSetup.downloadURL) }
                        }
                    }
                }
            }
        }
        .onAppear { ollama.refresh() }
    }

    private var ollamaText: String {
        switch ollama.state {
        case .unknown: "Checking…"
        case .unreachable: "Not running"
        case .modelMissing: "Running · \(ollama.model) not installed. Run “ollama pull \(ollama.model)” in Terminal."
        case .ready: "Running · \(ollama.model) installed"
        }
    }
}

// MARK: - Privacy

struct PrivacySection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Send nearby text and on-screen words to cloud cleanup", isOn: $model.settings.sendContextToCloud)
            }
            Section {
                Text(SettingsCopy.privacyStatic).foregroundStyle(.secondary)
            }
        }
    }
}
