import Foundation
import Synchronization
import Testing
import MurmurCore
@testable import MurmurEngines

private func req(_ t: String, context: ContextSnapshot? = nil) -> FormatRequest {
    FormatRequest(raw: RawTranscript(text: t), context: context, dictionary: ["Priya"])
}

@Suite("AppleFormatterTests")
struct AppleIntelligenceFormatterTests {
    @Test func availabilityCopy() {
        #expect(AppleAvailability.available.message == nil)
        #expect(AppleAvailability.deviceNotEligible.message == "This Mac doesn't support Apple Intelligence.")
        #expect(AppleAvailability.notEnabled.message == "Turn on Apple Intelligence in System Settings.")
        #expect(AppleAvailability.modelNotReady.message == "Apple Intelligence is still getting ready.")
        #expect(AppleAvailability.other("x").message?.contains("x") == true)
    }

    @Test func unavailableAtCallTimeThrows() async {
        let called = Mutex(false)
        let f = AppleIntelligenceFormatter(availability: { .notEnabled }, respond: { _, _, _ in called.withLock { $0 = true }; return "x" })
        await #expect(throws: EngineError.unavailable("Turn on Apple Intelligence in System Settings.")) {
            _ = try await f.format(req("hello"))
        }
        #expect(called.withLock { $0 } == false)
    }

    @Test func refusalThrows() async {
        let f = AppleIntelligenceFormatter(availability: { .available }, respond: { _, _, _ in throw EngineError.refused })
        await #expect(throws: EngineError.refused) { _ = try await f.format(req("hello")) }
    }

    @Test func buildsHintsStylePrompt() async throws {
        let seen = Mutex<(String, String, Int)>(("", "", 0))
        let f = AppleIntelligenceFormatter(availability: { .available }, respond: { s, u, n in
            seen.withLock { $0 = (s, u, n) }
            return "<think>x</think> Hello there. "
        })
        let ctx = ContextSnapshot(app: AppIdentity(name: "Notes", bundleId: "com.apple.Notes"), beforeText: "Meeting with Priya", selectedText: "", afterText: "", screenWords: [], isSecureField: false)
        let out = try await f.format(req("um hello there", context: ctx))
        #expect(out == "Hello there.")
        let (s, u, n) = seen.withLock { $0 }
        #expect(s.contains("never copy hint words"))
        #expect(u.contains("<app>Notes</app>") && u.contains("<hints>") && u.contains("<transcript>um hello there</transcript>"))
        #expect(n == OllamaFormatter.tokenCap(forRawWordCount: 3))
    }
}
