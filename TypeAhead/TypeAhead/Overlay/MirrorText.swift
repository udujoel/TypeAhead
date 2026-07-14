import Foundation

/// One line of Cotypist-style "mirror" ghost content: the tail of what the user already typed,
/// plus the completion that follows it. Rendered as one continuous two-tone line by
/// `CompletionOverlay.showMirror`/`updateMirror` — `typedTail` in the normal text color, `ghost`
/// in the ghost (tertiary) color.
struct MirrorLine: Equatable {
    let typedTail: String
    let ghost: String
}

/// Pure composition logic for the mirror presentation (WP-A). No AppKit — just string slicing —
/// so it's trivially unit-testable.
enum MirrorText {
    /// Builds a `MirrorLine` from the text before the cursor and the ghost completion.
    ///
    /// - `typedTail` is the LAST LINE of `textBeforeCursor` (text after the last `\n`, or the
    ///   whole string if there's no newline) — a mirror only ever shows the line currently being
    ///   typed, never earlier paragraphs.
    /// - When that line is longer than `maxTypedChars`, it's suffix-trimmed to fit: the last
    ///   `maxTypedChars` characters are kept, then — if that cut landed mid-word — trimmed
    ///   forward to the next word boundary (so the mirror never opens on a fragment of a word)
    ///   and prefixed with "…" so it visibly reads as a continuation rather than the true start
    ///   of the line.
    /// - `ghost` is passed through untouched.
    static func compose(textBeforeCursor: String, ghost: String, maxTypedChars: Int = 40) -> MirrorLine {
        let typedTail = trim(lastLine(of: textBeforeCursor), toMaxChars: maxTypedChars)
        return MirrorLine(typedTail: typedTail, ghost: ghost)
    }

    private static func lastLine(of text: String) -> String {
        guard let newlineIndex = text.lastIndex(of: "\n") else { return text }
        return String(text[text.index(after: newlineIndex)...])
    }

    private static func trim(_ line: String, toMaxChars maxChars: Int) -> String {
        guard maxChars > 0, line.count > maxChars else { return line }
        let tail = line.suffix(maxChars)
        guard let spaceIndex = tail.firstIndex(of: " ") else {
            // No word boundary in the trimmed tail at all (one very long "word") — just cut.
            return "…" + tail
        }
        let afterSpace = tail[tail.index(after: spaceIndex)...]
        guard !afterSpace.isEmpty else {
            // The only space was the very last character — nothing after it to start on, so
            // fall back to the raw cut rather than producing an empty tail.
            return "…" + tail
        }
        return "…" + afterSpace
    }
}
