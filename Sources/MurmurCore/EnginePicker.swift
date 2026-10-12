import Foundation

public enum EnginePicker {
    /// The English engine to route with: the preferred one if its model is ready, else the other if ready,
    /// else the preferred one (the controller then reports the missing model).
    public static func effectiveEnglish(preferred: String, parakeetReady: Bool, whisperReady: Bool) -> String {
        let preferWhisper = preferred == "whisperkit"
        let preferredReady = preferWhisper ? whisperReady : parakeetReady
        let otherReady = preferWhisper ? parakeetReady : whisperReady
        if preferredReady { return preferred }
        if otherReady { return preferWhisper ? "parakeet" : "whisperkit" }
        return preferred
    }
}
