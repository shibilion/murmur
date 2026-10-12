import Foundation

// MARK: - Key Input

public enum KeyInput: Equatable, Sendable {
    case fnDown(shift: Bool, t: TimeInterval)
    case fnUp(t: TimeInterval)
    case otherKeyDown(keyCode: Int, t: TimeInterval)
}

// MARK: - Hotkey Event

public enum HotkeyEvent: Equatable, Sendable {
    case start(DictationMode)
    case stop
    case toggleHandsFree(DictationMode)
    case cancel
    case abortedAsModifier
}

// MARK: - Gesture Recognizer

public struct GestureRecognizer: Sendable {
    // MARK: - State

    private enum State {
        case idle
        case holding(mode: DictationMode, downAt: TimeInterval)
        case maybeDoubleTap(firstDownAt: TimeInterval, mode: DictationMode)
        case handsFree(mode: DictationMode)
        case suppressed
    }

    private var state: State = .idle

    // MARK: - Public API

    public init() {}

    /// True when no gesture is in progress.
    public var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    /// Return to idle (e.g. when the event tap is re-enabled and Fn state may be stale).
    public mutating func reset() {
        state = .idle
    }

    public mutating func handle(_ input: KeyInput) -> [HotkeyEvent] {
        switch (state, input) {
        // MARK: - idle + fnDown
        case (.idle, .fnDown(let shift, let t)):
            let mode: DictationMode = shift ? .indian : .english
            state = .holding(mode: mode, downAt: t)
            return [.start(mode)]

        // MARK: - holding + fnDown (lost fnUp: resync)
        case (.holding, .fnDown(let shift, let t)):
            let mode: DictationMode = shift ? .indian : .english
            state = .holding(mode: mode, downAt: t)
            return [.cancel, .start(mode)]

        // MARK: - suppressed + fnDown (lost fnUp: start fresh)
        case (.suppressed, .fnDown(let shift, let t)):
            let mode: DictationMode = shift ? .indian : .english
            state = .holding(mode: mode, downAt: t)
            return [.start(mode)]

        // MARK: - holding + fnUp
        case (.holding(let mode, let downAt), .fnUp(let t)):
            let duration = t - downAt
            if duration >= 0.150 {
                // Long press → stop
                state = .idle
                return [.stop]
            } else {
                // Quick tap → cancel and enter maybeDoubleTap
                state = .maybeDoubleTap(firstDownAt: downAt, mode: mode)
                return [.cancel]
            }

        // MARK: - maybeDoubleTap + fnDown
        case (.maybeDoubleTap(let firstDownAt, let firstMode), .fnDown(let shift, let t)):
            let timeSinceFirst = t - firstDownAt
            if timeSinceFirst <= 0.350 {
                // Double-tap confirmed → toggleHandsFree, keeping the FIRST tap's mode
                state = .handsFree(mode: firstMode)
                return [.toggleHandsFree(firstMode)]
            } else {
                // Window expired → treat as new idle + fnDown
                let newMode: DictationMode = shift ? .indian : .english
                state = .holding(mode: newMode, downAt: t)
                return [.start(newMode)]
            }

        // MARK: - maybeDoubleTap + fnUp
        case (.maybeDoubleTap, .fnUp):
            // Window expired or other input comes → revert to idle
            state = .idle
            return []

        // MARK: - maybeDoubleTap + otherKeyDown
        case (.maybeDoubleTap, .otherKeyDown):
            // Window expired → revert to idle
            state = .idle
            return []

        // MARK: - handsFree + fnDown
        case (.handsFree, .fnDown):
            // Stop dictation and enter suppressed (so matching fnUp emits [])
            state = .suppressed
            return [.stop]

        // MARK: - handsFree + fnUp
        case (.handsFree, .fnUp):
            // Should not reach here if properly paired, but handle it
            return []

        // MARK: - handsFree + otherKeyDown(53 = Esc)
        case (.handsFree, .otherKeyDown(let keyCode, _)) where keyCode == 53:
            state = .idle
            return [.cancel]

        // MARK: - handsFree + otherKeyDown(other)
        case (.handsFree, .otherKeyDown):
            // Ignore typing during hands-free
            return []

        // MARK: - holding + otherKeyDown(53 = Esc)
        case (.holding, .otherKeyDown(let keyCode, _)) where keyCode == 53:
            state = .suppressed
            return [.cancel]

        // MARK: - holding + otherKeyDown(other)
        case (.holding, .otherKeyDown):
            // Fn+arrow = modifier → abort
            state = .suppressed
            return [.abortedAsModifier]

        // MARK: - suppressed + fnUp
        case (.suppressed, .fnUp):
            state = .idle
            return []

        // MARK: - suppressed + other
        case (.suppressed, _):
            // Stay suppressed, ignore all input until fnUp
            return []

        // MARK: - idle + other
        case (.idle, .fnUp),
             (.idle, .otherKeyDown):
            return []
        }
    }
}
