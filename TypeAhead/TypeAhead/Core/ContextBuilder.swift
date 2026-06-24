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
    /// Two cases based on how much the user has typed into the current sentence:
    /// • ≥ minTailChars chars: trim to the current sentence — it stands alone.
    /// • < minTailChars chars (a sentence just begun, or the cursor sitting right at a
    ///   boundary): keep at most ONE prior sentence as context — trim to the boundary
    ///   before the most recent one. The immediate prior sentence is coherent signal for
    ///   continuing the new thought; anything older is a different topic the model would
    ///   echo (e.g. "support," surfacing after "How are you doing today?" because the
    ///   160-char window spanned two paragraphs). Falls back to the full window only when
    ///   there is no earlier boundary (a single sentence — all the context we have).
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

        // NOTE: String.range(of:options:) with [.regularExpression, .backwards] is
        // unsupported by Foundation and silently finds the FIRST match, not the last.
        // Use NSRegularExpression.matches and take the final element instead.
        let boundaryPattern = #"[\.!\?\n][\s"')\]]*"#
        if let boundary = lastRegexRange(in: prefix, pattern: boundaryPattern) {
            let tail = String(prefix[boundary.upperBound...])
            let tailContent = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if tailContent.count >= minTailChars {
                // Current sentence is long enough to stand alone — trim here.
                prefix = tail
            } else {
                // Short or empty tail: the full 160-char window likely spans a prior paragraph
                // and the model will echo words from it. Keep at most ONE prior sentence —
                // trim to the boundary before the most recent one, so context is
                // [immediate prior sentence][current partial], dropping older topics.
                let beforeCurrentBoundary = String(prefix[..<boundary.lowerBound])
                if let prevBoundary = lastRegexRange(in: beforeCurrentBoundary, pattern: boundaryPattern) {
                    let oneSentenceBack = String(prefix[prevBoundary.upperBound...])
                    if !oneSentenceBack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        prefix = oneSentenceBack
                    }
                }
                // else: no earlier boundary (single sentence) — the full prefix is all the
                // context available, so keep it.
            }
        }

        // Prepend a compact screen-context hint so the model understands the user's topic
        // (e.g. code they're reading, a document they're composing). Capped at 120 chars
        // so small models aren't distracted by lengthy off-task OCR output.
        // Defense-in-depth: skip the hint when the OCR text reads as garble (symbol soup or
        // letter-substitution junk) that slipped through ScreenshotContextProvider's filter —
        // contaminated context hurts completions more than missing context helps.
        if let screen = screenContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !screen.isEmpty {
            let compact = String(screen.prefix(120))
            if OCRTextQuality.isLikelyReadable(compact) {
                return "[Screen: \(compact)]\n\(prefix)"
            }
        }
        return prefix
    }

    /// Returns true when the cursor sits right after a sentence terminator (`.!?` and
    /// full-width equivalents), skipping over trailing closing punctuation (`"'"')]}»`).
    /// Callers suppress completion generation at sentence boundaries — the model has no
    /// useful signal for the next clause until the user starts typing it.
    static func shouldSuppressAtSentenceEnd(textBeforeCursor: String) -> Bool {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        // Includes macOS Smart Quotes curly doubles (U+201C/201D) so "He said "done.""
        // is treated the same as the straight-quote equivalent.
        let closingPunct: Set<Character> = ["\"", "'", "\u{2019}", "\u{2018}", "\u{201C}", "\u{201D}", ")", "]", "}", "»"]
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

    /// Returns the range of the LAST regex match in `text`, or nil if no match.
    ///
    /// `String.range(of:options:)` with `[.regularExpression, .backwards]` is
    /// unsupported by Foundation and finds the first match instead of the last.
    /// This helper uses `NSRegularExpression.matches` to get all matches and picks
    /// the final one, giving the true rightmost occurrence.
    static func lastRegexRange(in text: String, pattern: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: ns).last.flatMap { Range($0.range, in: text) }
    }
}
