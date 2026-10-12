import Testing
@testable import MurmurCore

@Suite
struct EnginePickerTests {
    @Test func prefersParakeetWhenBothReady() {
        #expect(EnginePicker.effectiveEnglish(preferred: "parakeet", parakeetReady: true, whisperReady: true) == "parakeet")
    }
    @Test func fallsBackToWhisperWhenParakeetMissing() {
        #expect(EnginePicker.effectiveEnglish(preferred: "parakeet", parakeetReady: false, whisperReady: true) == "whisperkit")
    }
    @Test func returnsToParakeetWhenItBecomesReady() {
        #expect(EnginePicker.effectiveEnglish(preferred: "parakeet", parakeetReady: false, whisperReady: true) == "whisperkit")
        #expect(EnginePicker.effectiveEnglish(preferred: "parakeet", parakeetReady: true, whisperReady: true) == "parakeet")
    }
    @Test func honoursWhisperPreference() {
        #expect(EnginePicker.effectiveEnglish(preferred: "whisperkit", parakeetReady: true, whisperReady: true) == "whisperkit")
        #expect(EnginePicker.effectiveEnglish(preferred: "whisperkit", parakeetReady: true, whisperReady: false) == "parakeet")
    }
    @Test func keepsPreferredWhenNothingReady() {
        #expect(EnginePicker.effectiveEnglish(preferred: "parakeet", parakeetReady: false, whisperReady: false) == "parakeet")
    }
}
