import Foundation

/// Abstraction over the system pasteboard so the paste/restore dance is testable.
public protocol Pasteboarding {
    var changeCount: Int { get }
    /// Every item, every type, as raw Data.
    func snapshot() -> [[String: Data]]
    /// Writes `s` as plain text; when `concealed`, also adds the concealed marker type.
    func write(_ s: String, concealed: Bool)
    /// Replaces the pasteboard contents with `items` (empty clears it).
    func restore(_ items: [[String: Data]])
}

public struct ClipboardDance {
    public init() {}

    public func perform(
        _ text: String,
        pb: Pasteboarding,
        sendPaste: () -> Bool,
        sleep: (TimeInterval) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async -> InsertOutcome {
        let saved = pb.snapshot()
        pb.write(text, concealed: true)
        let countAfterWrite = pb.changeCount
        guard sendPaste() else { return .copiedOnly }
        await sleep(0.5)
        if pb.changeCount == countAfterWrite {
            pb.restore(saved)
        }
        return .pasted
    }
}
