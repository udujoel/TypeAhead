import Foundation

/// Turns a model's raw streamed output into the inline ghost text to display.
///
/// This is pure, dependency-free text logic deliberately kept out of
/// `InferenceEngine` (which links MLXLLM and can't run under `swift test`) so the
/// alignment rules — the part that decides what Tab inserts — are unit-testable.
enum GhostText {

    /// - Parameters:
    ///   - typed: the text already before the cursor (alignment mode only).
    ///   - raw: the model's raw output so far.
    ///   - isFillInMiddle: despite the name, this does NOT mean "a suffix is known" — it means
    ///     "the generation used assistant-prefill" (see InferenceEngine/HFBridge): the model's
    ///     raw output already IS the continuation, so prefix-alignment, first-line trimming, and
    ///     current-word-restatement stripping apply. InferenceEngine's only completion path uses
    ///     prefill unconditionally, so this is true on every real call regardless of whether the
    ///     cursor has trailing text. Suffix-awareness is the separate `suffix` parameter below —
    ///     see `trimSuffixOverlap`. Left named/typed as-is (rather than renamed to e.g.
    ///     `isPrefillMode`) to keep this change surgical; a future cleanup could split it out.
    ///   - maxWords: cap the displayed words to this many (0 = no cap). Enforces the
    ///     user's completion-length setting regardless of how much the model generates.
    ///   - suffix: text already after the cursor (from `ContextBuilder.buildSuffix`), when
    ///     known. When non-empty, the tail of the ghost is trimmed if it overlaps the head
    ///     of the suffix — see `trimSuffixOverlap`. Empty suffix (cursor at end of text, or
    ///     the keystroke-buffer fallback which has no AX suffix) leaves output unchanged.
    static func build(typed: String, raw: String, isFillInMiddle: Bool = false, maxWords: Int = 0, suffix: String = "") -> String {
        let cleaned = CompletionTextSanitizer.sanitize(raw)
        guard !cleaned.isEmpty else { return "" }

        var continuation: String
        var didStrip = false
        var stripProducedLeadingSpace = false
        if isFillInMiddle {
            // The output is the continuation. Keep only the current line — the model
            // often runs on into new sentences/lines we don't want inline.
            let firstLine = cleaned.prefix { $0 != "\n" }
            continuation = normalizeWhitespace(String(firstLine))
            // Guard against the model restating the partial current word (→ "woworking").
            let beforeStrip = continuation
            continuation = stripCurrentWordRestatement(typed: typed, continuation: continuation)
            didStrip = continuation != beforeStrip
            // When the stripped partial is itself a word (e.g. "do" from "do you want"),
            // the remaining text starts with a space (" you want"). Record before tidy() removes it.
            stripProducedLeadingSpace = didStrip && continuation.hasPrefix(" ")
        } else {
            continuation = alignedContinuation(typed: typed, output: cleaned)
        }

        continuation = tidy(continuation)
        if maxWords > 0 {
            continuation = clampWords(continuation, maxWords)
        }

        // Restore the word-boundary space that tidy() consumed when stripCurrentWordRestatement
        // produced it. E.g. typed="I do", raw="do you want" → strip → " you want" → tidy →
        // "you want" → ghost "I doyou want" ✗. didStrip=true prevents rawBeginsNewWord from
        // re-adding the space, so we restore it explicitly here.
        if stripProducedLeadingSpace, !continuation.isEmpty, !endsWithWhitespace(typed) {
            continuation = " " + continuation
        }

        // Preserve the word separator. If the model started a NEW word (its raw output
        // began with whitespace) and the text before the cursor doesn't already end with
        // a space, prepend one — so "work" + "for" reads "work for", not "workfor". When
        // the model continues the current word ("wor" + "king"), no space is added.
        // Exception: closing/terminal punctuation attaches directly without a leading space
        // ("How are you" + "?" should give "?" not " ?").
        // Exception: when stripCurrentWordRestatement stripped a restatement, the continuation
        // is a word suffix (not a new word) — the leading-space check must not fire even if the
        // original raw happened to start with whitespace.
        if !continuation.isEmpty, isFillInMiddle, !didStrip, rawBeginsNewWord(raw),
           !endsWithWhitespace(typed), !startsWithClosingPunctuation(continuation) {
            continuation = " " + continuation
        }

        // Quality gate: reject clearly-junk completions before showing them.
        guard isUsableGhost(continuation) else { return "" }

        // The model is now suffix-aware (its instruction includes what follows the cursor —
        // see PersonalizationEngine.buildInstruction), but small models still sometimes lead
        // straight into a restatement of it. Trim that overlap so Tab doesn't duplicate text
        // that's already there.
        if !suffix.isEmpty {
            continuation = trimSuffixOverlap(ghost: continuation, suffix: suffix)
            guard isUsableGhost(continuation) else { return "" }
        }

        return continuation
    }

    /// Closing/terminal punctuation that attaches directly to the preceding word (no leading space).
    /// Quotes (' and ") are intentionally excluded: whether a quote opens or closes a phrase is
    /// context-dependent, and forcing no-space before an opening quote gives "He said"hello" bugs.
    private static let closingPunctuation: Set<Character> = ["?", "!", ".", ",", ":", ";", ")", "]", "}"]

    /// True if `s` starts with a closing/terminal punctuation character.
    private static func startsWithClosingPunctuation(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        return closingPunctuation.contains(first)
    }

    /// True if the model's continuation starts a new word (first non-newline char is a space).
    private static func rawBeginsNewWord(_ raw: String) -> Bool {
        for ch in raw where ch != "\n" && ch != "\r" {
            return ch == " " || ch == "\t"
        }
        return false
    }

    private static func endsWithWhitespace(_ s: String) -> Bool {
        s.last.map { $0 == " " || $0 == "\n" || $0 == "\t" } ?? true
    }

    /// The partial word currently being typed: the trailing run of non-whitespace characters
    /// before the cursor. Empty when the text ends with whitespace (not mid-word).
    static func currentPartialWord(_ typed: String) -> String {
        String(typed.reversed().prefix { $0 != " " && $0 != "\n" && $0 != "\t" }.reversed())
    }

    /// In fill-in-middle mode the model should emit only the text AFTER the cursor, but small
    /// models sometimes restate the partial word the user is mid-typing (typed "wo", model
    /// emits "working") — inserting that verbatim duplicates the prefix ("woworking"). When the
    /// user is mid-word and the continuation begins with the current partial word, drop that
    /// overlap. Skips single-character partials (too risky — could merge a legitimate new word).
    static func stripCurrentWordRestatement(typed: String, continuation: String) -> String {
        guard !continuation.isEmpty, !endsWithWhitespace(typed) else { return continuation }
        let partial = currentPartialWord(typed)
        guard partial.count >= 2 else { return continuation }
        if continuation.lowercased().hasPrefix(partial.lowercased()) {
            return String(continuation.dropFirst(partial.count))
        }
        return continuation
    }

    /// Whether streaming can stop early because more tokens can't change the displayed ghost.
    ///
    /// The overlay shows only the first line (up to the first newline) capped at `maxWords`, so
    /// once the model has produced a complete first line — a newline following real content — or
    /// more than `maxWords` words on that line, further generation is wasted. Stopping there keeps
    /// suggestions snappy and saves battery. Sanitizing first means template scaffolding or a
    /// blank line emitted *before* any real content doesn't stop us prematurely.
    static func shouldStopStreaming(raw: String, maxWords: Int) -> Bool {
        let cleaned = CompletionTextSanitizer.sanitize(raw)
        guard !cleaned.isEmpty else { return false }
        // First line complete: a newline survives sanitization only when it sits between real
        // content (leading/trailing whitespace is trimmed), so its presence means the line ended.
        if cleaned.contains("\n") { return true }
        // Word cap exceeded: more than maxWords words means the first maxWords are complete and
        // the remainder would be clamped away. Exactly maxWords doesn't stop — the last word may
        // still be growing (e.g. "four" → "fourteen").
        if maxWords > 0 {
            let words = cleaned.split(separator: " ", omittingEmptySubsequences: true)
            if words.count > maxWords { return true }
        }
        return false
    }

    /// Keeps at most `maxWords` space-separated words.
    static func clampWords(_ text: String, _ maxWords: Int) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).joined(separator: " ")
    }

    /// Extracts the text the model added *after* what the user typed.
    ///
    /// Small models frequently restate the prefix — sometimes from earlier than our
    /// trimmed window — before adding new words. Returning the whole output in that
    /// case is what made Tab insert the first word of a full restatement. So when the
    /// output isn't a clean continuation, we anchor on the tail of the typed text,
    /// find its last occurrence in the output, and keep only what follows. If nothing
    /// aligns, we return "" rather than surface a restatement as a "completion".
    static func alignedContinuation(typed: String, output: String) -> String {
        let out = normalizeWhitespace(output)
        let typedNorm = normalizeWhitespace(typed)
        guard !out.isEmpty else { return "" }
        guard !typedNorm.isEmpty else { return out }

        let outLower = out.lowercased()
        let typedLower = typedNorm.lowercased()

        // 1. Clean continuation: output begins with everything typed.
        if outLower.hasPrefix(typedLower) {
            return String(out.dropFirst(typedNorm.count))
        }

        // 2. Restatement: anchor on the tail of the typed text, keep what follows its
        //    last occurrence (case-insensitive search on the original string, so the
        //    returned indices map back safely).
        let anchor = String(typedNorm.suffix(min(typedNorm.count, 60)))
        if anchor.count >= 6,
           let r = out.range(of: anchor, options: [.backwards, .caseInsensitive]) {
            return String(out[r.upperBound...])
        }

        // 3. User has typed past the model's output — nothing new to add.
        if typedLower.hasPrefix(outLower) { return "" }

        // 4. Boundary overlap: longest suffix of typed that is a prefix of output.
        let overlap = boundaryOverlap(typedLower: typedLower, outLower: outLower)
        if overlap > 0 { return String(out.dropFirst(overlap)) }

        // 5. No alignment — refuse to surface a full restatement.
        return ""
    }

    /// Trims a trailing overlap between `ghost` and the head of `suffix` — the text already
    /// sitting after the cursor. E.g. prefix "The quick brown ", suffix " jumps over", ghost
    /// "fox jumps over" → "fox": the model correctly continued with "fox" but then re-typed
    /// words that are already there, so the overlapping tail is cut.
    ///
    /// Only trims on a word boundary (the character before the cut is whitespace, or the
    /// entire ghost overlaps) so a partial-word coincidence can't slice a word in half —
    /// same caution as `stripCurrentWordRestatement`. Comparison is case-insensitive and
    /// against whitespace-normalized suffix so minor formatting differences don't block it.
    static func trimSuffixOverlap(ghost: String, suffix: String) -> String {
        let normalizedSuffix = normalizeWhitespace(suffix)
        guard !ghost.isEmpty, !normalizedSuffix.isEmpty else { return ghost }

        let ghostLower = ghost.lowercased()
        let suffixLower = normalizedSuffix.lowercased()

        var k = min(ghostLower.count, suffixLower.count)
        while k > 0 {
            let suffixPrefix = String(suffixLower.prefix(k))
            if ghostLower.hasSuffix(suffixPrefix) {
                let dropIndex = ghost.index(ghost.endIndex, offsetBy: -k)
                let onWordBoundary = dropIndex == ghost.startIndex
                    || ghost[ghost.index(before: dropIndex)] == " "
                if onWordBoundary {
                    let trimmed = String(ghost[..<dropIndex])
                    return trimmed.trimmingCharacters(in: .whitespaces)
                }
            }
            k -= 1
        }
        return ghost
    }

    /// Largest k where the last k chars of `typed` equal the first k chars of `out`.
    static func boundaryOverlap(typedLower: String, outLower: String) -> Int {
        var k = min(typedLower.count, outLower.count)
        while k > 0 {
            if typedLower.hasSuffix(String(outLower.prefix(k))) { return k }
            k -= 1
        }
        return 0
    }

    /// Strips a leading space and a matched pair of surrounding quotes.
    static func tidy(_ text: String) -> String {
        var s = text
        while s.first == " " { s.removeFirst() }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    static func normalizeWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Returns false for ghost text that is clearly junk — would confuse rather than help.
    ///
    /// Rejects:
    /// - A lone backslash (model outputting an escape or LaTeX fragment)
    /// - A standalone hyphen at word-start (model suggesting "co-working" for "co";
    ///   valid hyphens in compound words like "well-defined" are allowed via the word check)
    /// - Any string with no letters or digits UNLESS it's a standalone terminal punctuation
    ///   character (?, !, ), ], }) — those are useful punctuation suggestions.
    static func isUsableGhost(_ ghost: String) -> Bool {
        let s = ghost.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        // Standalone terminal/closing punctuation is a valid suggestion on its own.
        let usableStandalone: Set<Character> = ["?", "!", ")", "]", "}"]
        if s.count == 1, let only = s.first, usableStandalone.contains(only) { return true }
        // Otherwise must contain at least one letter or digit — stray commas, ellipses, etc. are useless.
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        // Lone backslash or backslash-only prefix.
        if s.hasPrefix("\\") && !s.dropFirst().contains(where: { $0.isLetter }) { return false }
        // Leading hyphen with no prior word context — e.g. "-working" for "co".
        // A hyphen IS valid mid-word ("well-" in "well-defined") but not as the
        // very first character of a ghost that would be appended to partial text.
        if s.hasPrefix("-"), let second = s.dropFirst().first, second.isLetter { return false }
        return true
    }
}
