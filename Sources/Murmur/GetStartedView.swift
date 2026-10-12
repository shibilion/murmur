import AVFoundation
import AppKit
import MurmurCore
import MurmurEngines
import SwiftUI

enum GetStartedCopy {
    static let whisperCaption = "Used for Hindi and Hinglish (Fn + Shift)"
    static let footer = "Hold Fn and talk to try it."
    static let globeFix = "Set “Press 🌐 key to” to Do Nothing"
    static let stepTitles = ["Choose a speech model", "Choose cleanup", "Allow access"]
    static let stepSubtitles = [
        "Murmur turns your voice into text on this Mac. Download at least one model to continue.",
        "Cleanup removes fillers and fixes punctuation. You can change this later in Settings.",
        "Murmur needs these to listen for Fn and type for you.",
    ]
}

struct GetStartedView: View {
    var model: GetStartedModel
    @Bindable var settings: SettingsModel
    @ObservedObject var models: DownloadManager
    var ollama: OllamaSetup
    let onDone: () -> Void

    private static let lastStep = 2

    /// Any speech model on its way (or ready) is enough to move on.
    private var speechStarted: Bool {
        ModelCatalog.all.filter { $0.kind == .speech }.contains { m in
            switch models.states[m.id] {
            case .downloading, .verifying, .preparing, .ready: true
            default: false
            }
        }
    }

    private var availability: ProviderAvailability {
        let q = models.states["qwen3-4b-instruct-gguf"]
        return ProviderAvailability(
            builtInReady: q == .ready || q == .preparing,
            appleAvailable: AppleIntelligenceFormatter.isCompiledIn && model.apple == .available,
            ollamaReachable: ollama.isReachable)
    }

    private var effectiveProvider: CleanupProvider { settings.settings.cleanupProvider.effective(availability) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Step \(model.step + 1) of \(Self.lastStep + 1)").font(.caption).foregroundStyle(.secondary)
            Text(GetStartedCopy.stepTitles[model.step]).font(.title2.bold()).padding(.bottom, 4)
            Text(GetStartedCopy.stepSubtitles[model.step]).foregroundStyle(.secondary).padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    switch model.step {
                    case 0: speechStep
                    case 1: cleanupStep
                    default: permissionsStep
                    }
                }
                .padding(.bottom, 4)
            }

            Spacer(minLength: 12)
            HStack {
                if model.step == Self.lastStep {
                    Text(GetStartedCopy.footer).foregroundStyle(.secondary)
                }
                Spacer()
                if model.step > 0 { Button("Back") { model.step -= 1 } }
                if model.step < Self.lastStep {
                    Button("Continue", action: advance)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.step == 0 && !speechStarted)
                } else {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.permissionsOK)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
    }

    private func advance() {
        model.step += 1
    }

    // MARK: Step 1

    @ViewBuilder private var speechStep: some View {
        ForEach(ModelCatalog.all.filter { $0.kind == .speech }) { m in
            ModelCardView(model: m, state: models.states[m.id], selected: false, selectable: false,
                          caption: m.id == "whisper-large-v3-turbo" ? GetStartedCopy.whisperCaption : nil) { b in
                ModelCardActions.perform(b, id: m.id, models: models) {}
            }
        }
    }

    // MARK: Step 2

    @ViewBuilder private var cleanupStep: some View {
        if let q = ModelCatalog.model("qwen3-4b-instruct-gguf") {
            ModelCardView(model: q, state: models.states[q.id], selected: effectiveProvider == .builtIn) { b in
                ModelCardActions.perform(b, id: q.id, models: models) { settings.settings.cleanupProvider = .builtIn }
            }
        }
        if AppleIntelligenceFormatter.isCompiledIn { appleCard }
        ModelCardView(
            name: "None", blurb: "Insert the transcript as spoken, without cleanup.",
            selected: effectiveProvider == .none,
            status: "Nothing to download",
            button: effectiveProvider == .none ? .selected : .useThis,
            onButton: { _ in settings.settings.cleanupProvider = .none })
    }

    @ViewBuilder private var appleCard: some View {
        let reason = model.apple.message
        ModelCardView(
            name: "Apple Intelligence", blurb: "Built into macOS. Nothing to download.",
            selected: effectiveProvider == .appleIntelligence,
            status: reason ?? "Ready", statusIsError: false,
            button: reason == nil ? (effectiveProvider == .appleIntelligence ? .selected : .useThis) : nil,
            onButton: { _ in settings.settings.cleanupProvider = .appleIntelligence },
            secondaryTitle: reason == nil ? nil : "Open Settings", onSecondary: model.openSiriSettings,
            dimmed: reason != nil)
    }

    // MARK: Step 3

    @ViewBuilder private var permissionsStep: some View {
        VStack(spacing: 0) {
            row("Microphone", detail: "Hears you while Fn is held.", ok: model.micOK,
                button: model.microphone == .notDetermined ? "Allow" : "Open Settings", action: model.grantMicrophone)
            Divider()
            row("Accessibility", detail: "Lets Murmur paste text into the active app.", ok: model.accessibility,
                button: "Grant", action: model.grantAccessibility)
            Divider()
            row("Input Monitoring", detail: "Lets Murmur see the Fn key.", ok: model.inputMonitoring,
                button: "Grant", action: model.grantInputMonitoring)
            Divider()
            row("Globe key", detail: model.globeDoNothing ? "Fn is free for dictation." : GetStartedCopy.globeFix,
                ok: model.globeDoNothing, button: "Open Settings",
                note: "Recommended", action: model.openKeyboardSettings)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ title: String, detail: String, ok: Bool, button: String?,
                     note: String? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .font(.title3)
                .accessibilityLabel(ok ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let note, !ok { Text(note).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            if !ok, let button { Button(button, action: action) }
        }
        .padding(12)
    }
}
