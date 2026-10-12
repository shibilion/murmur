import Foundation
import Testing
@testable import MurmurCore

@Suite("EvalFixture")
struct EvalFixtureTests {
    @Test func fixtureShape() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cleanup-eval.json")
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: url))
        #expect(cases.count == 30)
        let counts = Dictionary(grouping: cases, by: \.category).mapValues(\.count)
        #expect(counts == ["filler": 8, "selfcorrection": 5, "list": 4, "names": 4, "noanswer": 5, "hinglish": 4])
        #expect(Set(cases.map(\.id)).count == 30)
        for c in cases where c.category == "noanswer" { #expect(!(c.mustNotContain ?? []).isEmpty) }
        for c in cases where c.category == "hinglish" { #expect(c.mode == "indian") }
    }
}
