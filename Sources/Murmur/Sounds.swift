import AppKit

/// Start/stop cues. No sound on cancel.
@MainActor
enum Sounds {
    static func playStart(enabled: Bool) { play("Pop", enabled: enabled) }
    static func playStop(enabled: Bool) { play("Tink", enabled: enabled) }

    private static func play(_ name: String, enabled: Bool) {
        guard enabled, let sound = NSSound(named: name) else { return }
        sound.volume = 0.3
        sound.stop()
        sound.play()
    }
}
