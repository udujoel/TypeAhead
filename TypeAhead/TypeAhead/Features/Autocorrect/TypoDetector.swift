import AppKit

struct TypoFix: Sendable {
    let original: String
    let suggestion: String
}

enum TypoDetector {
    private static let checker = NSSpellChecker.shared

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
        return TypoFix(original: word, suggestion: first)
    }
}
