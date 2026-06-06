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
    ///   - isFillInMiddle: when true the model's output already IS the continuation
    ///     (raw-continuation / fill-in-middle), so prefix-alignment is skipped.
    ///   - maxWords: cap the displayed words to this many (0 = no cap). Enforces the
    ///     user's completion-length setting regardless of how much the model generates.
    static func build(typed: String, raw: String, isFillInMiddle: Bool = false, maxWords: Int = 0) -> String {
        let cleaned = CompletionTextSanitizer.sanitize(raw)
        guard !cleaned.isEmpty else { return "" }

        var continuation: String
        if isFillInMiddle {
            // The output is the continuation. Keep only the current line — the model
            // often runs on into new sentences/lines we don't want inline.
            let firstLine = cleaned.prefix { $0 != "\n" }
            continuation = normalizeWhitespace(String(firstLine))
        } else {
            continuation = alignedContinuation(typed: typed, output: cleaned)
        }

        continuation = tidy(continuation)
        if maxWords > 0 {
            continuation = clampWords(continuation, maxWords)
        }

        // Preserve the word separator. If the model started a NEW word (its raw output
        // began with whitespace) and the text before the cursor doesn't already end with
        // a space, prepend one — so "work" + "for" reads "work for", not "workfor". When
        // the model continues the current word ("wor" + "king"), no space is added.
        if !continuation.isEmpty, isFillInMiddle, rawBeginsNewWord(raw), !endsWithWhitespace(typed) {
            continuation = " " + continuation
        }
        return continuation
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
}
