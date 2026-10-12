import CoreGraphics
import Foundation
import MurmurCore

@MainActor
final class HotkeyMonitor {
    // nonisolated(unsafe) so the nonisolated deinit can tear down; only touched on the main thread otherwise.
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private var recognizer = GestureRecognizer()
    private var fnIsDown = false

    var onEvent: ((HotkeyEvent) -> Void)?

    // The tap is created on, and its source scheduled on, the main run loop, so the
    // callback always runs on the main thread.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        // Capture the timestamp before anything else.
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        // Read only plain values out of the event before entering the isolated closure.
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            MainActor.assumeIsolated { monitor.handleTapDisabled() }
        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            MainActor.assumeIsolated {
                monitor.handleFlagsChanged(keyCode: keyCode, flags: flags, timestamp: timestamp)
            }
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            MainActor.assumeIsolated {
                monitor.deliver(.otherKeyDown(keyCode: keyCode, t: timestamp))
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }
        guard CGPreflightListenEventAccess() else { return false }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        resetState()
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        teardown()
        resetState()
    }

    deinit {
        teardown()
    }

    private nonisolated func teardown() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func resetState() {
        recognizer.reset()
        fnIsDown = false
    }

    private func handleTapDisabled() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        let wasIdle = recognizer.isIdle
        resetState()
        // A gesture was in flight when the tap went away; tell the consumer to abandon it.
        if !wasIdle { onEvent?(.cancel) }
    }

    private func handleFlagsChanged(keyCode: Int, flags: CGEventFlags, timestamp: TimeInterval) {
        // Fn is detected via keycode 63 (kVK_Function); arrow/F-keys also set maskSecondaryFn.
        guard keyCode == 63 else { return }
        let down = flags.contains(.maskSecondaryFn)
        guard down != fnIsDown else { return }
        fnIsDown = down
        if down {
            deliver(.fnDown(shift: flags.contains(.maskShift), t: timestamp))
        } else {
            deliver(.fnUp(t: timestamp))
        }
    }

    private func deliver(_ input: KeyInput) {
        for event in recognizer.handle(input) {
            onEvent?(event)
        }
    }
}
