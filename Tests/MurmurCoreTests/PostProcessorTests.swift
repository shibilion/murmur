import Testing
@testable import MurmurCore

@Test func editDistanceCountsWords() {
    #expect(PostProcessor.wordEditDistance("a b c", "a x c") == 1)
}

@Test func usesRawWhenNovelWordsDominate() {
    #expect(PostProcessor.shouldUseRaw(raw: "send the report to priya today", formatted: "Here is a poem about reports", allowedExtra: [], mode: .english))
    #expect(!PostProcessor.shouldUseRaw(raw: "um send the report to priya today", formatted: "Send the report to Priya today.", allowedExtra: [], mode: .english))
}

@Test func selfCorrectionDeletionPasses() {
    #expect(!PostProcessor.shouldUseRaw(raw: "send it to Rahul no Anita", formatted: "Send it to Anita.", allowedExtra: [], mode: .english))
}

@Test func formattedListPasses() {
    #expect(!PostProcessor.shouldUseRaw(raw: "I need to buy milk eggs and bread", formatted: "I need to buy:\n- milk\n- eggs\n- bread", allowedExtra: [], mode: .english))
}

@Test func answerIsRejected() {
    #expect(PostProcessor.shouldUseRaw(raw: "what is the capital of France", formatted: "The capital of France is Paris.", allowedExtra: [], mode: .english))
}

@Test func hallucinatedAdditionRejected() {
    #expect(PostProcessor.shouldUseRaw(raw: "send the report", formatted: "Send the report to the whole leadership team by Friday evening.", allowedExtra: [], mode: .english))
}

@Test func contextWordsAllowed() {
    #expect(!PostProcessor.shouldUseRaw(raw: "email priya about it", formatted: "Email Priya Raghunathan about it.", allowedExtra: ["Raghunathan"], mode: .english))
}

@Test func indianModeOnlyLengthCheck() {
    #expect(!PostProcessor.shouldUseRaw(raw: "हां हिंदी मोड is working", formatted: "Haan, Hindi mode is working.", allowedExtra: [], mode: .indian))
}

@Test func snippetsCaseInsensitiveWholePhrase() {
    #expect(PostProcessor.apply("Email it to my email please", snippets: [.init(trigger: "my email", expansion: "me@x.dev")], replacements: [:]) == "Email it to me@x.dev please")
}

@Test func replacementsWholeWordOnly() {
    #expect(PostProcessor.apply("cat catalog", snippets: [], replacements: ["cat": "dog"]) == "dog catalog")
}

@Test func leadingSpace() {
    #expect(PostProcessor.withLeadingSpace("Hi", charBeforeCursor: "o") == " Hi")
    #expect(PostProcessor.withLeadingSpace("Hi", charBeforeCursor: " ") == "Hi")
    #expect(PostProcessor.withLeadingSpace("Hi", charBeforeCursor: "\n") == "Hi")
    #expect(PostProcessor.withLeadingSpace("Hi", charBeforeCursor: nil) == "Hi")
    #expect(PostProcessor.withLeadingSpace(".", charBeforeCursor: "o") == ".")
}

@Test func snippetExpansionWithDollarIsLiteral() {
    #expect(PostProcessor.apply("quote the price", snippets: [.init(trigger: "the price", expansion: "$99 or \\1")], replacements: [:]) == "quote $99 or \\1")
}

@Test func replacementValueWithDollarIsLiteral() {
    #expect(PostProcessor.apply("pay cost", snippets: [], replacements: ["cost": "$5"]) == "pay $5")
}

@Test func devanagariSnippetMatches() {
    #expect(PostProcessor.apply("कल मीटिंग है", snippets: [.init(trigger: "मीटिंग", expansion: "meeting")], replacements: [:]) == "कल meeting है")
}

@Test func devanagariReplacementWholeWordOnly() {
    #expect(PostProcessor.apply("मीटिंगें मीटिंग", snippets: [], replacements: ["मीटिंग": "meeting"]) == "मीटिंगें meeting")
}

@Test func editDistanceKeepsDevanagariLetters() {
    #expect(PostProcessor.wordEditDistance("कल मीटिंग है।", "कल मीटिंग है") == 0)
}
