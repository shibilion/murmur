import Carbon
import Foundation

/// Finds the virtual keycode that types "v" in the current keyboard layout.
/// Cached; refreshed when the selected input source changes. Falls back to 9 (ANSI V).
final class KeyboardLayout: @unchecked Sendable {
    static let shared = KeyboardLayout()

    private let lock = NSLock()
    private var cachedV: CGKeyCode?
    private var observer: NSObjectProtocol?

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.lock.lock()
            self?.cachedV = nil
            self?.lock.unlock()
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    var keyCodeForV: CGKeyCode {
        lock.lock()
        defer { lock.unlock() }
        if let cachedV { return cachedV }
        let code = Self.lookup() ?? 9
        cachedV = code
        return code
    }

    private static func lookup() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let kbType = UInt32(LMGetKbdType())

        for code in 0..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDown), 0, kbType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                return CGKeyCode(code)
            }
        }
        return nil
    }
}
