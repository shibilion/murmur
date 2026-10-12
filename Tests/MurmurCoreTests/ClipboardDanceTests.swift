import Foundation
import Testing
@testable import MurmurCore

final class FakePasteboard: Pasteboarding, @unchecked Sendable {
    var changeCount = 1
    var items: [[String: Data]] = []
    var writes: [(String, Bool)] = []
    var restored: [[[String: Data]]] = []

    func snapshot() -> [[String: Data]] { items }
    func write(_ s: String, concealed: Bool) {
        writes.append((s, concealed))
        var item: [String: Data] = ["public.utf8-plain-text": Data(s.utf8)]
        if concealed { item["org.nspasteboard.ConcealedType"] = Data() }
        items = [item]
        changeCount += 1
    }
    func restore(_ items: [[String: Data]]) {
        restored.append(items)
        self.items = items
        changeCount += 1
    }
}

@Suite struct ClipboardDanceTests {
    @Test func writesConcealedAndRestoresAfter500ms() async {
        let pb = FakePasteboard()
        let original: [[String: Data]] = [["public.utf8-plain-text": Data("old".utf8)]]
        pb.items = original
        nonisolated(unsafe) var sleeps: [TimeInterval] = []
        nonisolated(unsafe) var restoredAtSleep = -1
        let out = await ClipboardDance().perform("hello", pb: pb, sendPaste: { true }, sleep: { s in
            sleeps.append(s); restoredAtSleep = pb.restored.count
        })
        #expect(out == .pasted)
        #expect(pb.writes.count == 1 && pb.writes[0].0 == "hello" && pb.writes[0].1 == true)
        #expect(sleeps == [0.5])
        #expect(restoredAtSleep == 0)
        #expect(pb.restored == [original])
    }

    @Test func skipsRestoreIfChangeCountMoved() async {
        let pb = FakePasteboard()
        pb.items = [["public.utf8-plain-text": Data("old".utf8)]]
        let out = await ClipboardDance().perform("hello", pb: pb, sendPaste: { true }, sleep: { _ in pb.changeCount += 1 })
        #expect(out == .pasted)
        #expect(pb.restored.isEmpty)
    }

    @Test func restoresAllPasteboardTypes() async {
        let pb = FakePasteboard()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 255])
        let original: [[String: Data]] = [["public.png": png, "public.utf8-plain-text": Data("caption".utf8)]]
        pb.items = original
        _ = await ClipboardDance().perform("x", pb: pb, sendPaste: { true }, sleep: { _ in })
        #expect(pb.items == original)
        #expect(pb.items[0]["public.png"] == png)
    }

    @Test func pasteFailureReturnsCopiedOnly() async {
        let pb = FakePasteboard()
        pb.items = [["public.utf8-plain-text": Data("old".utf8)]]
        nonisolated(unsafe) var slept = false
        let out = await ClipboardDance().perform("hello", pb: pb, sendPaste: { false }, sleep: { _ in slept = true })
        #expect(out == .copiedOnly)
        #expect(pb.restored.isEmpty)
        #expect(!slept)
        #expect(pb.items[0]["public.utf8-plain-text"] == Data("hello".utf8))
    }

    @Test func concealedMarkerWritten() async {
        let pb = FakePasteboard()
        _ = await ClipboardDance().perform("secret", pb: pb, sendPaste: { false }, sleep: { _ in })
        #expect(pb.items[0]["org.nspasteboard.ConcealedType"] == Data())
        #expect(pb.items[0]["public.utf8-plain-text"] == Data("secret".utf8))
    }

    @Test func emptyClipboardRestoredToEmpty() async {
        let pb = FakePasteboard()
        _ = await ClipboardDance().perform("hello", pb: pb, sendPaste: { true }, sleep: { _ in })
        #expect(pb.restored.count == 1)
        #expect(pb.items.isEmpty)
    }
}
