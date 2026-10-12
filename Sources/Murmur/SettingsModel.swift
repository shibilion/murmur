import AppKit
import Foundation
import MurmurCore
import Observation

/// Editable copy of `Settings`. Every change is reported to `onChange` at once (so the controller's
/// cache stays current) and written to disk after a 300 ms pause.
@MainActor
@Observable
final class SettingsModel {
    var settings: Settings {
        didSet {
            guard !suppress, settings != oldValue else { return }
            onChange?(settings)
            scheduleSave()
        }
    }

    /// The frontmost app when the window was opened, for "Add current app…".
    var capturedApp: (name: String, bundleId: String)?

    @ObservationIgnored var onChange: ((Settings) -> Void)?
    @ObservationIgnored private let save: (Settings) -> Void
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suppress = false

    init(initial: Settings, save: @escaping (Settings) -> Void) {
        settings = initial
        self.save = save
    }

    /// Replaces the model's copy with newer settings from elsewhere (the menu) without echoing them back.
    func refresh(_ newer: Settings) {
        guard newer != settings else { return }
        suppress = true
        settings = newer
        suppress = false
    }

    /// Writes any pending change immediately.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save(settings)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.save(self.settings)
        }
    }

    func addCapturedAppRule() {
        guard let app = capturedApp, !settings.rules.contains(where: { $0.bundleId == app.bundleId }) else { return }
        settings.rules.append(AppRule(bundleId: app.bundleId))
    }

    static func appName(forBundleId id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
