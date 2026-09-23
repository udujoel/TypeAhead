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
    /// - Parameter language: `NSSpellChecker` language (the English-variant setting); nil = the
    ///   checker's own current language.
    static func check(word: String, language: String? = nil) -> TypoFix? {
        let language = language ?? checker.language()
        guard word.count > 1 else { return nil }
        let range = checker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        guard range.location != NSNotFound else { return nil }
        guard let guesses = checker.guesses(
            forWordRange: range,
            in: word,
            language: language,
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
    /// - The token is NOT a prefix of a valid dictionary word — the user may simply
    ///   still be typing it. Dogfooding: "buil" (heading for "built") was "corrected"
    ///   to "boil" mid-word. A genuine typo like "recieve" or "helpp" has no valid
    ///   continuation, so it still fires immediately.
    /// - NSSpellChecker considers it misspelled and offers a suggestion different from
    ///   the typed word.
    static func correction(in textBeforeCursor: String, language: String? = nil) -> TypoFix? {
        guard let lastChar = textBeforeCursor.last, !lastChar.isWhitespace else { return nil }
        let word = lastWord(in: textBeforeCursor)
        guard word.count >= 3,
              word.first != ":",
              word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        guard !isPrefixOfValidWord(word, language: language) else { return nil }
        guard let fix = check(word: word, language: language),
              fix.suggestion.lowercased() != word.lowercased() else { return nil }
        return fix
    }

    /// True when `word` is a strict prefix of at least one valid dictionary word — i.e. the
    /// user is plausibly mid-typing it ("buil" → "build"/"built") and correcting now would
    /// mangle a word they haven't finished. Uses NSSpellChecker's partial-word completions,
    /// filtered to genuine prefix extensions (the API also returns fuzzy suggestions).
    static func isPrefixOfValidWord(_ word: String, language: String? = nil) -> Bool {
        let language = language ?? checker.language()
        guard let completions = checker.completions(
            forPartialWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word,
            language: language,
            inSpellDocumentWithTag: 0
        ) else { return false }
        let lower = word.lowercased()
        return completions.contains { candidate in
            let candidateLower = candidate.lowercased()
            return candidateLower.hasPrefix(lower) && candidateLower != lower
        }
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
