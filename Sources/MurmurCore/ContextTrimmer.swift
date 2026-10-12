import Foundation

public enum ContextTrimmer {
    // Built-in list of about 150 common English stopwords
    private static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any",
        "are", "aren't", "as", "at", "be", "because", "been", "before", "being", "below",
        "between", "both", "but", "by", "can't", "cannot", "could", "couldn't", "did", "didn't",
        "do", "does", "doesn't", "doing", "don't", "down", "during", "each", "few", "for",
        "from", "further", "had", "hadn't", "has", "hasn't", "have", "haven't", "having", "he",
        "he'd", "he'll", "he's", "her", "here", "here's", "hers", "herself", "him", "himself",
        "his", "how", "how's", "i", "i'd", "i'll", "i'm", "i've", "if", "in", "into", "is",
        "isn't", "it", "it's", "its", "itself", "just", "k", "l", "let's", "like", "m",
        "me", "might", "mightn't", "more", "most", "mustn't", "my", "myself", "no", "nor",
        "not", "of", "off", "on", "once", "only", "or", "other", "ought", "our", "ours",
        "ourselves", "out", "over", "own", "p", "r", "s", "same", "shan't", "she", "she'd",
        "she'll", "she's", "should", "shouldn't", "so", "some", "such", "t", "than", "that",
        "that's", "the", "their", "theirs", "them", "themselves", "then", "there", "there's",
        "these", "they", "they'd", "they'll", "they're", "they've", "this", "those", "through",
        "to", "too", "under", "until", "up", "v", "very", "w", "was", "wasn't", "we", "we'd",
        "we'll", "we're", "we've", "were", "weren't", "what", "what's", "when", "when's", "where",
        "where's", "which", "while", "who", "who's", "whom", "why", "why's", "with", "won't",
        "would", "wouldn't", "x", "y", "you", "you'd", "you'll", "you're", "you've", "your",
        "yours", "yourself", "yourselves", "z"
    ]

    /// Kept small on purpose: every context character is prompt-eval work for the local model.
    static let screenWordLimit = 80

    /// Trims a context snapshot for safe sending to the cleanup model.
    /// Returns nil if the field is marked as secure.
    /// Keeps last 400 characters of beforeText, first 150 of afterText, first 400 of selectedText,
    /// and processes screenWords through distinctiveWords() to deduplicate and cap at 80.
    public static func trim(_ snapshot: ContextSnapshot) -> ContextSnapshot? {
        guard !snapshot.isSecureField else {
            return nil
        }

        let trimmedBefore = trimLast(snapshot.beforeText, limit: 400)
        let trimmedAfter = trimFirst(snapshot.afterText, limit: 150)
        let trimmedSelected = trimFirst(snapshot.selectedText, limit: 400)
        let trimmedScreenWords = distinctiveWords(from: snapshot.screenWords.joined(separator: " "), limit: screenWordLimit)

        return ContextSnapshot(
            app: snapshot.app,
            beforeText: trimmedBefore,
            selectedText: trimmedSelected,
            afterText: trimmedAfter,
            screenWords: trimmedScreenWords,
            isSecureField: snapshot.isSecureField
        )
    }

    /// Extracts distinctive words from text for use as spelling hints.
    /// Filters out stopwords and common short words, deduplicates case-insensitively,
    /// prioritizes words with uppercase letters, digits, or underscores,
    /// and caps the result at the specified limit (default 200).
    public static func distinctiveWords(from text: String, limit: Int = 200) -> [String] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        var priorityWords: [String] = []
        var normalWords: [String] = []
        var seenLowercase: Set<String> = []

        for token in tokens {
            // Strip leading and trailing punctuation
            let cleaned = stripPunctuation(token)

            // Skip short words
            guard cleaned.count >= 2 else {
                continue
            }

            // Skip stopwords (case-insensitive)
            let lowerCleaned = cleaned.lowercased()
            guard !stopwords.contains(lowerCleaned) else {
                continue
            }

            // Skip if we've already seen this word (case-insensitive)
            guard !seenLowercase.contains(lowerCleaned) else {
                continue
            }

            seenLowercase.insert(lowerCleaned)

            // Check if this word is "priority" (has uppercase, digit, or underscore)
            let isPriority = cleaned.contains { char in
                char.isUppercase || char.isNumber || char == "_"
            }

            if isPriority {
                priorityWords.append(cleaned)
            } else {
                normalWords.append(cleaned)
            }
        }

        // Combine priority first, then normal words, and cap at limit
        let combined = priorityWords + normalWords
        return Array(combined.prefix(limit))
    }

    // MARK: - Private Helpers

    /// Keeps the last `limit` characters of the string, counting grapheme clusters.
    private static func trimLast(_ text: String, limit: Int) -> String {
        let chars = Array(text)
        guard chars.count > limit else {
            return text
        }
        let startIndex = chars.count - limit
        return String(chars[startIndex...])
    }

    /// Keeps the first `limit` characters of the string, counting grapheme clusters.
    private static func trimFirst(_ text: String, limit: Int) -> String {
        let chars = Array(text)
        guard chars.count > limit else {
            return text
        }
        return String(chars[0..<limit])
    }

    /// Strips leading and trailing punctuation from a token.
    private static func stripPunctuation(_ token: String) -> String {
        let punctuationCharacters = CharacterSet.punctuationCharacters
        var result = token

        // Strip leading punctuation
        while let first = result.first, CharacterSet(charactersIn: String(first)).isSubset(of: punctuationCharacters) {
            result.removeFirst()
        }

        // Strip trailing punctuation
        while let last = result.last, CharacterSet(charactersIn: String(last)).isSubset(of: punctuationCharacters) {
            result.removeLast()
        }

        return result
    }
}
