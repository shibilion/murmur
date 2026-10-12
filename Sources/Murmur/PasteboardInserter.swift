import AppKit
import ApplicationServices
import Carbon
import MurmurCore

/// `Pasteboarding` over `NSPasteboard.general`. Only ever created and used inside the inserter's @MainActor task.
struct SystemPasteboard: Pasteboarding {
    private var pb: NSPasteboard { .general }

    var changeCount: Int { pb.changeCount }

    func snapshot() -> [[String: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type.rawValue] = data }
            }
            return dict
        }
    }

    func write(_ s: String, concealed: Bool) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(s, forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
        if concealed {
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        pb.writeObjects([item])
    }

    func restore(_ items: [[String: Data]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pb.writeObjects(restored)
    }
}

final class PasteboardInserter: TextInserting, Sendable {
    init() {}

    func insert(_ text: String) async -> InsertOutcome {
        await Task { @MainActor in
            let pb = SystemPasteboard()
            return await ClipboardDance().perform(
                text, pb: pb,
                sendPaste: { Self.sendCommandV() },
                sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
        }.value
    }

    /// Fails when not trusted or secure event input is on. Never verifies a focused text field.
    private static func sendCommandV() -> Bool {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return false }
        let keyCode = KeyboardLayout.shared.keyCodeForV
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
