import ServiceManagement

/// Launch at login through `SMAppService.mainApp`. Works best when Murmur.app is in /Applications.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns an error message to show inline, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't change login item: \(error.localizedDescription)"
        }
    }
}
