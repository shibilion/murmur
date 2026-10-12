import Testing
@testable import MurmurCore

@Test func trimsBeforeToLast400() {
    let beforeText = String(repeating: "a", count: 4000) + String(repeating: "b", count: 400)
    let snapshot = ContextSnapshot(
        app: AppIdentity(name: "Test", bundleId: "com.test"),
        beforeText: beforeText,
        selectedText: "",
        afterText: "",
        screenWords: [],
        isSecureField: false
    )
    let result = ContextTrimmer.trim(snapshot)
    #expect(result?.beforeText == String(repeating: "b", count: 400))
}

@Test func trimsAfterToFirst150() {
    let afterText = String(repeating: "c", count: 150) + String(repeating: "d", count: 4000)
    let snapshot = ContextSnapshot(
        app: AppIdentity(name: "Test", bundleId: "com.test"),
        beforeText: "",
        selectedText: "",
        afterText: afterText,
        screenWords: [],
        isSecureField: false
    )
    let result = ContextTrimmer.trim(snapshot)
    #expect(result?.afterText == String(repeating: "c", count: 150))
}

@Test func trimsSelectedToFirst400() {
    let selectedText = String(repeating: "e", count: 1500)
    let snapshot = ContextSnapshot(
        app: AppIdentity(name: "Test", bundleId: "com.test"),
        beforeText: "",
        selectedText: selectedText,
        afterText: "",
        screenWords: [],
        isSecureField: false
    )
    let result = ContextTrimmer.trim(snapshot)
    #expect(result?.selectedText.count == 400)
}

@Test func shortFieldsUnchanged() {
    let snapshot = ContextSnapshot(
        app: AppIdentity(name: "Test", bundleId: "com.test"),
        beforeText: "hi",
        selectedText: "",
        afterText: "there",
        screenWords: [],
        isSecureField: false
    )
    let result = ContextTrimmer.trim(snapshot)
    #expect(result?.beforeText == "hi")
    #expect(result?.afterText == "there")
}

@Test func secureFieldReturnsNil() {
    let snapshot = ContextSnapshot(
        app: AppIdentity(name: "Test", bundleId: "com.test"),
        beforeText: "secret",
        selectedText: "",
        afterText: "",
        screenWords: [],
        isSecureField: true
    )
    let result = ContextTrimmer.trim(snapshot)
    #expect(result == nil)
}

@Test func countsGraphemesNotUTF16() {
    let beforeText = String(repeating: "कि", count: 1200)
    let snapshot = ContextSnapshot(
        app: AppIdentity(name: "Test", bundleId: "com.test"),
        beforeText: beforeText,
        selectedText: "",
        afterText: "",
        screenWords: [],
        isSecureField: false
    )
    let result = ContextTrimmer.trim(snapshot)!
    #expect(result.beforeText.count == 400)
    #expect(result.beforeText == String(repeating: "कि", count: 400))
}

@Test func distinctiveDropsStopwordsAndDupes() {
    let words = ContextTrimmer.distinctiveWords(from: "the The Priya priya and meeting MEETING")
    #expect(words == ["Priya", "meeting"])
}

@Test func distinctivePriorityFirst() {
    let words = ContextTrimmer.distinctiveWords(from: "budget review Q4 api_key Sarvam")
    #expect(words == ["Q4", "api_key", "Sarvam", "budget", "review"])
}

@Test func distinctiveStripsPunctuation() {
    let words = ContextTrimmer.distinctiveWords(from: "Hello, (Priya)!")
    #expect(words == ["Hello", "Priya"])
}

@Test func distinctiveCapsAtLimit() {
    var tokens = [String]()
    for i in 0..<300 {
        tokens.append("w\(i)")
    }
    let input = tokens.joined(separator: " ")
    let words = ContextTrimmer.distinctiveWords(from: input)
    #expect(words.count == 200)
    #expect(words.first == "w0")
}

@Test func screenWordsDedupedAndCapped() {
    var screenWords = [String]()
    for i in 0..<250 {
        screenWords.append("word\(i)")
    }
    // Add duplicates
    for i in 0..<50 {
        screenWords.append("word\(i)")
    }
    let snapshot = ContextSnapshot(
        app: AppIdentity(name: "Test", bundleId: "com.test"),
        beforeText: "",
        selectedText: "",
        afterText: "",
        screenWords: screenWords,
        isSecureField: false
    )
    let result = ContextTrimmer.trim(snapshot)!
    #expect(result.screenWords.count == 80)
}
