import AppKit
import MurmurCore
import MurmurEngines
import SwiftUI

/// Lazily created, reused Settings window. Activating the app is allowed here (never for the overlay).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private let models: DownloadManager
    private let ollama: OllamaSetup
    private let secrets: any SecretStoring
    private let history: any HistoryStoring
    private var window: NSWindow?
    var onOpenAbout: (() -> Void)?

    init(model: SettingsModel, models: DownloadManager, ollama: OllamaSetup,
         secrets: any SecretStoring, history: any HistoryStoring) {
        self.model = model
        self.models = models
        self.ollama = ollama
        self.secrets = secrets
        self.history = history
    }

    func show(current: MurmurCore.Settings) {
        // Captured before activating, while the previous app is still frontmost.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           let id = app.bundleIdentifier {
            model.capturedApp = (app.localizedName ?? id, id)
        }
        model.refresh(current)

        if window == nil {
            let view = SettingsView(model: model, models: models, ollama: ollama, secrets: secrets, history: history, onOpenAbout: onOpenAbout)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Murmur Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 520))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.flush() }
}
