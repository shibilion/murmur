import Foundation

public struct EvalContext: Codable, Sendable, Equatable {
    public var beforeText: String
    public var screenWords: [String]
}

public struct EvalCase: Codable, Sendable, Equatable {
    public var id: String
    public var category: String
    /// "english" or "indian".
    public var mode: String
    public var raw: String
    public var expected: String
    public var mustNotContain: [String]?
    public var context: EvalContext?
}

public enum EvalVerdict: Sendable, Equatable { case pass, near, fail }

/// Scores a formatter output against the expected text for the cleanup eval.
public enum EvalScorer {
    /// Collapses every run of whitespace (including newlines) to one space and trims the ends.
    public static func normalise(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// pass: equal after whitespace normalisation and no forbidden substring (case-insensitive).
    /// near: not a pass, but within one word edit of expected and no forbidden substring.
    public static func score(got: String, expected: String, mustNotContain: [String]) -> EvalVerdict {
        let lower = got.lowercased()
        if mustNotContain.contains(where: { lower.contains($0.lowercased()) }) { return .fail }
        if normalise(got) == normalise(expected) { return .pass }
        return PostProcessor.wordEditDistance(got, expected) <= 1 ? .near : .fail
    }
}
