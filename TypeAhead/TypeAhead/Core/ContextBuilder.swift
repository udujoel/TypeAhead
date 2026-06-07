import Foundation

struct TextContext: Sendable {
    let textBeforeCursor: String
    let textAfterCursor: String
    let appName: String
    let windowTitle: String
}

enum ContextBuilder {
    private static let maxPrefixChars = 160   // smaller = faster first token on small models
    private static let maxSuffixChars = 120   // text after the cursor, for fill-in-middle

    /// Minimum characters the trimmed tail must have before we discard the prior context.
    /// When the user just started a new sentence / paragraph and has typed fewer than
    /// this many chars, we keep the full 160-char prefix so the model has enough context
    /// to produce a coherent suggestion. 25 chars ≈ "I love coding." — enough to anchor.
    private static let minTailChars = 25

    /// Builds a compact prompt: the text immediately before the cursor, trimmed
    /// to the current sentence/line when that line is long enough to stand alone.
    ///
    /// If trimming would leave fewer than `minTailChars` characters (e.g. the user just
    /// started a new paragraph), the full 160-char window is kept so the model can use
    /// the surrounding context rather than guessing from 3-4 typed chars.
    ///
    /// `clipboard`/`history` are accepted for API compatibility but intentionally
    /// excluded — small models complete more accurately from a focused prompt.
    static func buildPrompt(
        context: TextContext,
        clipboard: String?,
        history: [String],
        customInstructions: String,
        screenContext: String? = nil
    ) -> String {
        var prefix = String(context.textBeforeCursor.suffix(maxPrefixChars))

        // Trim to the start of the current sentence/line ONLY when the resulting tail
        // is substantial enough to be self-contained. If the user just typed a few
        // characters on a new line, keeping the prior context gives the model much
        // better signal than the trimmed 8-char stub.
        if let boundary = prefix.range(
            of: #"[\.!\?\n][\s"')\]]*"#,
            options: [.regularExpression, .backwards]
        ) {
            let tail = String(prefix[boundary.upperBound...])
            let tailContent = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if tailContent.count >= minTailChars {
                prefix = tail
            }
            // else: keep the full prefix — the current sentence is too short to stand alone.
        }

        // Prepend a compact screen-context hint so the model understands the user's topic
        // (e.g. code they're reading, a document they're composing). Capped at 120 chars
        // so small models aren't distracted by lengthy off-task OCR output.
        if let screen = screenContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !screen.isEmpty {
            let compact = String(screen.prefix(120))
            return "[Screen: \(compact)]\n\(prefix)"
        }
        return prefix
    }

    /// Returns true when the cursor sits right after a sentence terminator (`.!?` and
    /// full-width equivalents), skipping over trailing closing punctuation (`"'"')]}»`).
    /// Callers suppress completion generation at sentence boundaries — the model has no
    /// useful signal for the next clause until the user starts typing it.
    static func shouldSuppressAtSentenceEnd(textBeforeCursor: String) -> Bool {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let closingPunct: Set<Character> = ["\"", "'", "\u{2019}", "\u{2018}", ")", "]", "}", "»"]
        let trimmed = textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        for char in trimmed.reversed() {
            if closingPunct.contains(char) { continue }
            return terminators.contains(char)
        }
        return false
    }

    /// Returns the partial word the user is currently typing (characters after the
    /// last whitespace before the cursor), or `nil` when the cursor is at a word
    /// boundary (trailing space or empty). Callers use this to decide between
    /// completing the current word (no leading space in ghost) vs starting a new one.
    static func currentWord(context: TextContext) -> String? {
        let before = context.textBeforeCursor
        guard let last = before.last, !last.isWhitespace else { return nil }
        // Walk backwards to find where the current word starts.
        var idx = before.endIndex
        while idx > before.startIndex {
            let prev = before.index(before: idx)
            if before[prev].isWhitespace { break }
            idx = prev
        }
        let word = String(before[idx...])
        return word.isEmpty ? nil : word
    }

    /// The text immediately after the cursor, trimmed to the end of the current
    /// sentence/line. Empty when the cursor is at the end of the text (the common
    /// case) — callers treat empty as "use plain continuation, not fill-in-middle".
    static func buildSuffix(context: TextContext) -> String {
        let suffix = String(context.textAfterCursor.prefix(maxSuffixChars))
        if let boundary = suffix.range(of: #"[\.!\?\n]"#, options: .regularExpression) {
            return String(suffix[..<boundary.upperBound])
        }
        return suffix
    }
}
