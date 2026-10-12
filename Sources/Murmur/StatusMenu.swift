import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import MurmurCore

/// Pure text for the menu's first line (kept free of AppKit so it reads clearly).
enum StatusLine {
    static func text(settings: Settings, ollamaUp: Bool, permissionsOK: Bool) -> String {
        if !permissionsOK { return "Permission needed · check System Settings" }
        let stt = settings.cloudBoost ? "Groq" : (settings.englishEngine == "whisperkit" ? "WhisperKit" : "Parakeet")
        if settings.strength == .off { return "Ready · \(stt) · cleanup off" }
        if settings.cloudBoost { return "Ready · \(stt) + Claude" }
        return ollamaUp ? "Ready · \(stt) + \(settings.ollamaModel)" : "Ready · \(stt) · cleanup off"
    }
}

enum Permissions {
    static func allGranted() -> Bool {
        AXIsProcessTrusted()
            && CGPreflightListenEventAccess()
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    /// The items are disabled while these are nil.
    var onOpenSettings: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var onOpenAbout: (() -> Void)?

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let settings: () -> Settings
    private let updateSettings: (@escaping (inout Settings) -> Void) -> Void
    private let history: any HistoryStoring
    private let inserter: any TextInserting

    private var recent: [HistoryEntry] = []
    private(set) var isRecording = false { didSet { updateIcon() } }
    private(set) var permissionsOK = true { didSet { updateIcon() } }
    private(set) var ollamaUp = false
    private var timers: [Timer] = []

    init(
        settings: @escaping () -> Settings,
        updateSettings: @escaping (@escaping (inout Settings) -> Void) -> Void,
        history: any HistoryStoring,
        inserter: any TextInserting
    ) {
        self.settings = settings
        self.updateSettings = updateSettings
        self.history = history
        self.inserter = inserter
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateIcon()
        rebuild()
        refreshHistory()
        checkPermissions()
        checkOllama()
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissions() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOllama() }
        })
    }

    // MARK: - State inputs

    func setRecording(_ recording: Bool) { isRecording = recording }

    func refreshHistory() {
        Task { [weak self] in
            guard let self else { return }
            let entries = await self.history.recent(10)
            self.recent = entries
            self.rebuild()
        }
    }

    func checkPermissions() {
        let ok = Permissions.allGranted()
        if ok != permissionsOK { permissionsOK = ok; rebuild() }
    }

    private func checkOllama() {
        Task { [weak self] in
            var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
            req.timeoutInterval = 1
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 1
            cfg.timeoutIntervalForResource = 1
            let up: Bool
            if let (_, resp) = try? await URLSession(configuration: cfg).data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 { up = true } else { up = false }
            guard let self else { return }
            if up != self.ollamaUp { self.ollamaUp = up; self.rebuild() }
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        let name: String
        if !permissionsOK { name = "exclamationmark.triangle" }
        else if isRecording { name = "waveform.badge.mic" }
        else { name = "waveform" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Murmur")
        image?.isTemplate = true
        item.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { refreshHistory(); checkPermissions() }

    private func rebuild() {
        let s = settings()
        menu.removeAllItems()

        let status = NSMenuItem(title: StatusLine.text(settings: s, ollamaUp: ollamaUp, permissionsOK: permissionsOK),
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let cloud = NSMenuItem(title: "Cloud boost", action: #selector(toggleCloud), keyEquivalent: "")
        cloud.target = self
        cloud.state = s.cloudBoost ? .on : .off
        menu.addItem(cloud)

        let cleanup = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, strength) in [("Off", CleanupStrength.off), ("Light", .light), ("Normal", .normal)] {
            let it = NSMenuItem(title: title, action: #selector(setStrength(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = strength.rawValue
            it.state = s.strength == strength ? .on : .off
            sub.addItem(it)
        }
        cleanup.submenu = sub
        menu.addItem(cleanup)
        menu.addItem(.separator())

        let last = NSMenuItem(title: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "v")
        last.keyEquivalentModifierMask = [.control, .command]
        last.target = self
        menu.addItem(last)
        let raw = NSMenuItem(title: "Paste raw (no cleanup)", action: #selector(pasteRaw), keyEquivalent: "")
        raw.target = self
        menu.addItem(raw)

        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let hist = NSMenu()
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            hist.addItem(empty)
        }
        for (i, entry) in recent.enumerated() {
            let flat = entry.final.replacingOccurrences(of: "\n", with: " ")
            let title = flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
            let it = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            hist.addItem(it)
        }
        historyItem.submenu = hist
        menu.addItem(historyItem)
        menu.addItem(.separator())

        let setup = NSMenuItem(title: "Get started…", action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        setup.isEnabled = onOpenSetup != nil
        menu.addItem(setup)
        let about = NSMenuItem(title: "About Murmur", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        about.isEnabled = onOpenAbout != nil
        menu.addItem(about)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        prefs.isEnabled = onOpenSettings != nil
        menu.addItem(prefs)
        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleCloud() { updateSettings { $0.cloudBoost.toggle() }; rebuild() }

    @objc private func setStrength(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let strength = CleanupStrength(rawValue: raw) else { return }
        updateSettings { $0.strength = strength }
        rebuild()
    }

    @objc private func pasteLast() { paste { $0.final } }
    @objc private func pasteRaw() { paste { $0.raw } }

    private func paste(_ pick: @escaping (HistoryEntry) -> String) {
        Task { [history, inserter] in
            guard let entry = await history.recent(1).first else { return }
            // Let the menu close and focus return to the previous app before pasting.
            try? await Task.sleep(for: .milliseconds(300))
            _ = await inserter.insert(pick(entry))
        }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard recent.indices.contains(sender.tag) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(recent[sender.tag].final, forType: .string)
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openSetup() { onOpenSetup?() }
    @objc private func openAbout() { onOpenAbout?() }
}
