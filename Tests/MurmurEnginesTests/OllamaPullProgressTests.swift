import Testing
@testable import MurmurEngines

@Suite struct OllamaPullProgressTests {
    @Test func fractionFromCompletedAndTotal() {
        let line = #"{"status":"pulling abc","digest":"sha256:abc","total":2000,"completed":500}"#
        #expect(OllamaPullProgress.fraction(line: line) == 0.25)
    }

    @Test func statusOnlyLineHasNoFraction() {
        #expect(OllamaPullProgress.fraction(line: #"{"status":"pulling manifest"}"#) == nil)
    }

    @Test func zeroTotalHasNoFraction() {
        #expect(OllamaPullProgress.fraction(line: #"{"status":"x","total":0,"completed":0}"#) == nil)
    }

    @Test func garbageHasNoFraction() {
        #expect(OllamaPullProgress.fraction(line: "not json") == nil)
        #expect(OllamaPullProgress.fraction(line: "") == nil)
    }

    @Test func fractionIsClampedToOne() {
        #expect(OllamaPullProgress.fraction(line: #"{"total":10,"completed":20}"#) == 1.0)
    }

    @Test func successAndErrorLines() {
        #expect(OllamaPullProgress.isSuccess(line: #"{"status":"success"}"#))
        #expect(!OllamaPullProgress.isSuccess(line: #"{"status":"pulling"}"#))
        #expect(OllamaPullProgress.errorMessage(line: #"{"error":"pull model manifest: file does not exist"}"#) == "pull model manifest: file does not exist")
        #expect(OllamaPullProgress.errorMessage(line: #"{"status":"success"}"#) == nil)
    }
}

@Suite struct OllamaStateRuleTests {
    @Test func failedStateSurvivesRefresh() {
        #expect(!OllamaStateRule.probeMayReplace(pulling: false, failed: true))
        #expect(!OllamaStateRule.probeMayReplace(pulling: true, failed: false))
        #expect(OllamaStateRule.probeMayReplace(pulling: false, failed: false))
    }
}
