import AppKit
import MurmurCore
import SwiftUI

/// Overlay copy.
enum OverlayCopy {
    static func listening(_ mode: DictationMode) -> String {
        mode == .english ? "Listening · EN" : "Listening · HI"
    }
    static let handsFree = "Hands-free · tap Fn to stop"
    static let cleaning = "Cleaning up…"
    static let micUnavailable = "Microphone unavailable"
    static let micOff = "Microphone access is off"

    static func text(for notice: Notice) -> String {
        switch notice {
        case .usedLocal: "Cloud slow · used local"
        case .copiedPressCmdV: "Copied, press ⌘V"
        case .cleanupOff: "Cleanup off"
        case .warmingUp: "Preparing speech model (one-time, can take a few minutes)…"
        case .nothingHeard: "Nothing heard"
        case .busy: "Still finishing…"
        case .transcriptionFailed: "Couldn't transcribe"
        case .speechModelDownloading: "Speech model still downloading"
        }
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var mode: DictationMode = .english
    @Published var handsFree = false
    @Published var notice: String?
    /// Set by `Notice.warmingUp`; stays until the state leaves `.transcribing`.
    @Published var warmingText: String?
    @Published var level: Float = 0

    var isVisible: Bool { notice != nil || warmingText != nil || state != .idle }

    var text: String {
        if let warmingText { return warmingText }
        if let notice { return notice }
        switch state {
        case .idle: return ""
        case .recording: return handsFree ? OverlayCopy.handsFree : OverlayCopy.listening(mode)
        case .transcribing, .formatting, .inserting: return OverlayCopy.cleaning
        }
    }

    var showsBars: Bool { notice == nil && warmingText == nil && state == .recording }
}

private struct PillView: View {
    @ObservedObject var model: OverlayModel

    private var barColor: Color { model.mode == .english ? .green : .orange }

    var body: some View {
        HStack(spacing: 8) {
            if model.showsBars {
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        let weight: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
                        Capsule()
                            .fill(barColor)
                            .frame(width: 3, height: 4 + CGFloat(min(1, model.level * weight[i])) * 14)
                    }
                }
                .frame(height: 18)
                .animation(.easeOut(duration: 0.08), value: model.level)
            }
            Text(model.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class OverlayPanel {
    let model = OverlayModel()
    private let panel: NSPanel
    private var noticeTask: Task<Void, Never>?
    private var fadeToken = 0

    private static let size = NSSize(width: 360, height: 44)
    private static let noticeDuration: Duration = .milliseconds(1500)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PillView(model: model))
    }

    // MARK: - Inputs

    func setMode(_ mode: DictationMode, handsFree: Bool) {
        model.mode = mode
        model.handsFree = handsFree
    }

    func setLevel(_ level: Float) { model.level = level }

    func handle(_ event: DictationEvent) {
        switch event {
        case .stateChanged(let state):
            model.state = state
            if state != .transcribing { model.warmingText = nil }
            if state == .idle { model.handsFree = false; model.level = 0 }
            refresh()
        case .notice(.warmingUp):
            model.warmingText = OverlayCopy.text(for: .warmingUp)
            refresh()
        case .notice(let notice):
            showMessage(OverlayCopy.text(for: notice))
        }
    }

    /// Shows a one-line notice for 1.5 s, then returns to whatever the state calls for.
    func showMessage(_ text: String) {
        noticeTask?.cancel()
        model.notice = text
        refresh()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled, let self else { return }
            self.model.notice = nil
            self.refresh()
        }
    }

    // MARK: - Visibility

    private func refresh() {
        if model.isVisible { present() } else { fadeOut() }
    }

    private func present() {
        fadeToken += 1
        reposition()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard panel.isVisible else { return }
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeToken == token else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 80)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }
}
