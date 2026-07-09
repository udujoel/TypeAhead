import AppKit

struct TypoFix: Sendable, Equatable {
    let original: String
    let suggestion: String
    /// Character count of the misspelled word to delete backward from the cursor.
    let misspelledLength: Int
}

enum TypoDetector {
    nonisolated(unsafe) private static let checker = NSSpellChecker.shared

    /// Checks a single isolated word. Returns nil if correctly spelled or no suggestion found.
    static func check(word: String) -> TypoFix? {
        guard word.count > 1 else { return nil }
        let range = checker.checkSpelling(of: word, startingAt: 0)
        guard range.location != NSNotFound else { return nil }
        guard let guesses = checker.guesses(
            forWordRange: range,
            in: word,
            language: checker.language(),
            inSpellDocumentWithTag: 0
        ), let first = guesses.first else { return nil }
        return TypoFix(original: word, suggestion: first, misspelledLength: word.count)
    }

    /// Checks the last token in `textBeforeCursor` for a spelling error.
    ///
    /// Returns a fix only when:
    /// - The cursor is mid-word (text does not end in whitespace).
    /// - The last token is ≥ 3 purely alphabetic characters (no digits, punctuation,
    ///   or `:` prefix — those are handled by the emoji path or are likely code/URLs).
    /// - NSSpellChecker considers it misspelled and offers a suggestion different from
    ///   the typed word.
    static func correction(in textBeforeCursor: String) -> TypoFix? {
        guard let lastChar = textBeforeCursor.last, !lastChar.isWhitespace else { return nil }
        let word = lastWord(in: textBeforeCursor)
        guard word.count >= 3,
              word.first != ":",
              word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        guard let fix = check(word: word),
              fix.suggestion.lowercased() != word.lowercased() else { return nil }
        return fix
    }

    /// Extracts the last contiguous non-whitespace token from the end of `text`.
    static func lastWord(in text: String) -> String {
        var chars: [Character] = []
        for char in text.reversed() {
            if char.isWhitespace { break }
            chars.append(char)
        }
        return String(chars.reversed())
    }
}
