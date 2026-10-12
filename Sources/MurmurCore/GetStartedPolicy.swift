import Foundation

public enum GetStartedPolicy {
    /// Show Get started at launch when no speech model is present, a permission is missing, or the flow was never
    /// finished. Verifying and preparing count as present, so upgraders mid-migration don't see the window.
    public static func shouldShow(speechStates: [CardState], permissionsOK: Bool, onboarded: Bool) -> Bool {
        let present = speechStates.contains { s in
            switch s {
            case .ready, .verifying, .preparing: true
            default: false
            }
        }
        return !present || !permissionsOK || !onboarded
    }
}
