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

    /// Builds a compact prompt: the text immediately before the cursor, trimmed
    /// to the current sentence/line. The keystroke buffer accumulates everything
    /// typed since launch, so without trimming the prompt balloons with unrelated
    /// earlier text and first-token latency suffers badly.
    ///
    /// `clipboard`/`history` are accepted for API compatibility but intentionally
    /// excluded — small models complete more accurately from a focused prompt.
    static func buildPrompt(
        context: TextContext,
        clipboard: String?,
        history: [String],
        customInstructions: String
    ) -> String {
        var prefix = String(context.textBeforeCursor.suffix(maxPrefixChars))

        // Trim to the start of the current sentence/line when a boundary exists,
        // so the model focuses on what the user is actively writing.
        if let boundary = prefix.range(
            of: #"[\.!\?\n][\s"')\]]*"#,
            options: [.regularExpression, .backwards]
        ) {
            let tail = String(prefix[boundary.upperBound...])
            if !tail.trimmingCharacters(in: .whitespaces).isEmpty {
                prefix = tail
            }
        }

        return prefix
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
