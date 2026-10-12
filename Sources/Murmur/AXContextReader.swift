import AppKit
import ApplicationServices
import MurmurCore

/// Reads the text around the cursor and nearby on-screen words from the focused app via Accessibility.
/// All AX calls run off the main thread. Never logs any text content.
final class AXContextReader: ContextReading, Sendable {
    private static let budget: TimeInterval = 0.15
    private static let maxElements = 300
    private static let manualAXPids = PidSet()

    init() {}

    func snapshot() async -> ContextSnapshot? {
        await Task.detached(priority: .userInitiated) { Self.readSnapshot() }.value
    }

    func charBeforeCursor() async -> Character? {
        await Task.detached(priority: .userInitiated) { Self.readCharBeforeCursor() }.value
    }

    private static func readCharBeforeCursor() -> Character? {
        let deadline = Date().addingTimeInterval(budget)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Float(budget))
        guard let focused = element(system, kAXFocusedUIElementAttribute), Date() < deadline else { return nil }
        AXUIElementSetMessagingTimeout(focused, Float(budget))
        guard !isSecure(focused), Date() < deadline else { return nil }
        return readText(focused)?.before.last
    }

    /// Password fields are never read: role AXSecureTextField, or a text field with that subrole.
    private static func isSecure(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute)
        if role == "AXSecureTextField" { return true }
        return role == "AXTextField" && string(el, kAXSubroleAttribute) == "AXSecureTextField"
    }

    // MARK: - Reading

    private static func readSnapshot() -> ContextSnapshot? {
        let deadline = Date().addingTimeInterval(budget)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let identity = AppIdentity(name: app.localizedName ?? "", bundleId: app.bundleIdentifier ?? "")

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Float(budget))
        if manualAXPids.insertIfNew(app.processIdentifier) {
            // Chromium/Electron expose an empty tree unless asked; errors are ignored.
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Float(budget))
        guard let focused = element(system, kAXFocusedUIElementAttribute)
                ?? element(appElement, kAXFocusedUIElementAttribute)
        else { return nil }
        AXUIElementSetMessagingTimeout(focused, Float(budget))

        if isSecure(focused) {
            return ContextSnapshot(app: identity, beforeText: "", selectedText: "", afterText: "",
                                   screenWords: [], isSecureField: true)
        }

        let text = readText(focused)
        var words: [String] = []
        var url: String?
        if let window = element(focused, kAXWindowAttribute) ?? element(appElement, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(window, Float(budget))
            url = urlString(window)
            words = collectWords(window, deadline: deadline)
        }
        var withURL = identity
        withURL.url = url
        return ContextSnapshot(
            app: withURL,
            beforeText: text?.before ?? "", selectedText: text?.selected ?? "", afterText: text?.after ?? "",
            screenWords: words, isSecureField: false)
    }

    private static func readText(_ el: AXUIElement) -> (before: String, selected: String, after: String)? {
        guard let value = string(el, kAXValueAttribute),
              let rangeRef = attribute(el, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0
        else { return nil }
        let ns = value as NSString
        let loc = min(range.location, ns.length)
        let len = min(range.length, ns.length - loc)
        return (ns.substring(to: loc),
                ns.substring(with: NSRange(location: loc, length: len)),
                ns.substring(from: loc + len))
    }

    private static func collectWords(_ window: AXUIElement, deadline: Date) -> [String] {
        var out: [String] = []
        var queue: [AXUIElement] = [window]
        var index = 0
        var visited = 0
        while index < queue.count, visited < maxElements, Date() < deadline {
            let el = queue[index]
            index += 1
            visited += 1
            let role = string(el, kAXRoleAttribute)
            if !isSecure(el), role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" {
                for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let s = string(el, key), !s.isEmpty { out.append(s) }
                }
            }
            if let children = attribute(el, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return out.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    private static func urlString(_ window: AXUIElement) -> String? {
        if let ref = attribute(window, kAXURLAttribute) {
            if let url = ref as? URL { return url.absoluteString }
            if let s = ref as? String, !s.isEmpty { return s }
        }
        if let doc = string(window, kAXDocumentAttribute), !doc.isEmpty { return doc }
        return nil
    }

    // MARK: - AX helpers

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        attribute(el, name) as? String
    }

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let ref = attribute(el, name), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
}

/// Thread-safe set of pids already given AXManualAccessibility.
private final class PidSet: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    func insertIfNew(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pids.insert(pid).inserted
    }
}
