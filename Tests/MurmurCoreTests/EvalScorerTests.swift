import Foundation
import Testing
@testable import MurmurCore

@Suite("EvalScorer")
struct EvalScorerTests {
    @Test func exactAfterWhitespaceNormalisation() {
        #expect(EvalScorer.normalise("  Hello \n  world\t!  ") == "Hello world !")
        #expect(EvalScorer.score(got: "Hello   world.\n", expected: "Hello world.", mustNotContain: []) == .pass)
        #expect(EvalScorer.score(got: "Hello world", expected: "Hello world.", mustNotContain: []) != .pass)
    }

    @Test func mustNotContainIsCaseInsensitive() {
        let r = EvalScorer.score(got: "The capital is PARIS.", expected: "The capital is PARIS.", mustNotContain: ["paris"])
        #expect(r != .pass)
        #expect(EvalScorer.score(got: "Fine.", expected: "Fine.", mustNotContain: ["paris"]) == .pass)
    }

    @Test func nearWithinOneWord() {
        #expect(EvalScorer.score(got: "Send it to Anita today.", expected: "Send it to Anita.", mustNotContain: []) == .near)
        #expect(EvalScorer.score(got: "Send it to Anita now today.", expected: "Send it to Anita.", mustNotContain: []) == .fail)
    }
}
