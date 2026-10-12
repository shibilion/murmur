import AppKit
import MurmurCore
import MurmurEngines
import SwiftUI

/// Lazily created, reused Get started window. Polls permissions every second while visible.
/// Closing it never stops downloads: they belong to the `DownloadManager`.
@MainActor
final class GetStartedWindowController: NSObject, NSWindowDelegate {
    static let completedKey = "didCompleteOnboarding"

    let model = GetStartedModel()
    private let models: DownloadManager
    private let settings: SettingsModel
    private let ollama: OllamaSetup
    private var window: NSWindow?

    init(models: DownloadManager, settings: SettingsModel, ollama: OllamaSetup) {
        self.models = models
        self.settings = settings
        self.ollama = ollama
    }

    /// No speech model is ready, a permission is missing, or the flow was never finished.
    static func shouldShowAtLaunch(models: DownloadManager) -> Bool {
        GetStartedPolicy.shouldShow(
            speechStates: ModelCatalog.all.filter { $0.kind == .speech }.map { (models.states[$0.id] ?? .notDownloaded).cardState },
            permissionsOK: !GetStartedModel.anyPermissionMissing(),
            onboarded: UserDefaults.standard.bool(forKey: completedKey))
    }

    func show() {
        if window == nil {
            let view = GetStartedView(model: model, settings: settings, models: models, ollama: ollama) { [weak self] in
                self?.finish()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Get started"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        if window?.isVisible != true { model.step = 0 }
        model.startPolling()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { model.stopPolling() }
}
