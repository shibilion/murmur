import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import MurmurCore
import MurmurEngines
import Observation

/// Live state of the Get started window: the step, the permission checklist and Apple Intelligence availability.
/// `poll()` runs every second while the window is visible.
@MainActor
@Observable
final class GetStartedModel {
    var step = 0
    private(set) var microphone: AVAuthorizationStatus = .notDetermined
    private(set) var accessibility = false
    private(set) var inputMonitoring = false
    private(set) var globeDoNothing = true
    private(set) var apple: AppleAvailability = .available
    var onInputMonitoringGranted: (() -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    static let micURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let inputMonitoringURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    static let siriURL = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
    static let keyboardURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    var micOK: Bool { microphone == .authorized }
    var permissionsOK: Bool { micOK && accessibility && inputMonitoring }

    /// True when a check that matters at launch fails.
    static func anyPermissionMissing() -> Bool { !Permissions.allGranted() }

    func poll() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        let wasGranted = inputMonitoring
        inputMonitoring = CGPreflightListenEventAccess()
        if inputMonitoring, !wasGranted { onInputMonitoringGranted?() }
        let fn = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        globeDoNothing = GlobeKeySetting.isDoNothing(fn)
        apple = AppleIntelligenceFormatter.availability()
    }

    func startPolling() {
        pollTask?.cancel()
        poll()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.poll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Grant actions

    func grantMicrophone() {
        if microphone == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio); poll() }
        } else {
            NSWorkspace.shared.open(Self.micURL)
        }
    }

    func grantAccessibility() {
        // The prompt key's constant is a C global; use its documented string value.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(Self.accessibilityURL)
    }

    func grantInputMonitoring() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(Self.inputMonitoringURL)
    }

    func openKeyboardSettings() { NSWorkspace.shared.open(Self.keyboardURL) }
    func openSiriSettings() { NSWorkspace.shared.open(Self.siriURL) }
}
