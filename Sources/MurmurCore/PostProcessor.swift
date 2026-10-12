import Foundation

// MARK: - Snippet

public struct Snippet: Codable, Sendable, Equatable {
    public var trigger: String
    public var expansion: String

    public init(trigger: String, expansion: String) {
        self.trigger = trigger
        self.expansion = expansion
    }
}

// MARK: - PostProcessor

public enum PostProcessor {
    /// Calculate word-level Levenshtein distance between two strings.
    /// Words are obtained by lowercasing, stripping Unicode punctuation, and splitting on whitespace.
    public static func wordEditDistance(_ a: String, _ b: String) -> Int {
        let wordsA = tokenizeWords(a)
        let wordsB = tokenizeWords(b)
        return levenshteinDistance(wordsA, wordsB)
    }

    private static let questionWords: Set<String> = ["what", "who", "whom", "whose", "where", "when", "why", "how", "which"]

    /// Safety check: should the formatter output be discarded in favour of the raw text?
    /// Returns true when EITHER
    /// (a) english mode and more than 40% of the output words are novel (not in raw, `allowedExtra`), OR
    /// (b) the output has more than `Int(1.5 * rawWordCount) + 3` words.
    /// (c) english mode, the raw text opens with a question word, and the output has any new word.
    /// In indian mode only (b) applies, because transliteration changes every word.
    /// List markers ("-", "•", "1.") are not counted as words.
    public static func shouldUseRaw(
        raw: String,
        formatted: String,
        allowedExtra: [String],
        mode: DictationMode
    ) -> Bool {
        let rawWords = tokenizeWords(raw)
        let outWords = tokenizeWords(formatted)

        if outWords.count > Int(1.5 * Double(rawWords.count)) + 3 {
            return true
        }
        guard mode == .english else { return false }

        var known = Set(rawWords)
        for extra in allowedExtra { known.formUnion(tokenizeWords(extra)) }
        let novel = outWords.filter { !known.contains($0) }.count
        if Double(novel) / Double(max(1, outWords.count)) > 0.4 { return true }

        // (c) A dictated question that comes back with any new word was probably answered, not
        // cleaned. A single answer word ("Paris") is below the 40% bar, so catch it explicitly.
        if novel > 0, let first = rawWords.first, questionWords.contains(first) {
            return true
        }
        return false
    }

    /// Apply snippets and replacements to text.
    /// Snippets are applied first (case-insensitive, whole-phrase at word boundaries).
    /// Then replacements are applied (case-insensitive, whole-word only).
    public static func apply(
        _ text: String,
        snippets: [Snippet],
        replacements: [String: String]
    ) -> String {
        var result = text

        // Apply snippets first
        for snippet in snippets {
            result = applySnippet(result, trigger: snippet.trigger, expansion: snippet.expansion)
        }

        // Apply replacements
        for (pattern, replacement) in replacements {
            result = applyReplacement(result, pattern: pattern, replacement: replacement)
        }

        return result
    }

    /// Add a leading space if appropriate.
    /// Adds a space when:
    /// - charBeforeCursor is non-nil and not whitespace or newline
    /// - text doesn't start with `. , ; : ! ? )`
    /// - text is not empty
    public static func withLeadingSpace(_ text: String, charBeforeCursor: Character?) -> String {
        // Don't add space to empty text
        if text.isEmpty {
            return text
        }

        // Check if text starts with punctuation that shouldn't have a space
        let punctuation = Set(".,;:!?)")
        if let firstChar = text.first, punctuation.contains(firstChar) {
            return text
        }

        // Only add space if charBeforeCursor is non-nil and not whitespace or newline
        guard let char = charBeforeCursor else {
            return text
        }

        if char.isWhitespace || char.isNewline {
            return text
        }

        return " " + text
    }

    // MARK: - Private Helpers

    /// Tokenize a string into words: split on all whitespace (including newlines), drop list markers,
    /// lowercase and strip Unicode punctuation.
    private static func tokenizeWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { !isListMarker($0) }
            .map { removePunctuation($0.lowercased()) }
            .filter { !$0.isEmpty }
    }

    /// "-", "•", "*", or a number followed by "." or ")".
    private static func isListMarker(_ token: Substring) -> Bool {
        if token == "-" || token == "•" || token == "*" { return true }
        guard let last = token.last, last == "." || last == ")" else { return false }
        let digits = token.dropLast()
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    /// Remove Unicode punctuation from a string.
    private static func removePunctuation(_ text: String) -> String {
        var result = ""
        for char in text {
            if !char.isPunctuation {
                result.append(char)
            }
        }
        return result
    }

    /// Calculate Levenshtein distance between two arrays of words.
    private static func levenshteinDistance(_ a: [String], _ b: [String]) -> Int {
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m {
            dp[i][0] = i
        }
        for j in 0...n {
            dp[0][j] = j
        }

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(
                        dp[i - 1][j],     // deletion
                        dp[i][j - 1],     // insertion
                        dp[i - 1][j - 1]  // substitution
                    )
                }
            }
        }

        return dp[m][n]
    }

    /// Apply a snippet replacement with case-insensitive matching at word boundaries.
    private static func applySnippet(_ text: String, trigger: String, expansion: String) -> String {
        let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
        let pattern = "\\b\(escapedTrigger)\\b"
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)
        let escapedExpansion = NSRegularExpression.escapedTemplate(for: expansion)
        let result = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: escapedExpansion)
        return result
    }

    /// Apply a replacement with whole-word, case-insensitive matching.
    private static func applyReplacement(_ text: String, pattern: String, replacement: String) -> String {
        let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
        let regexPattern = "\\b\(escapedPattern)\\b"
        let regex = try! NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        let result = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: escapedReplacement)
        return result
    }
}
