import Foundation

/// Word alternatives (Cotypist Labs): other choices for the FIRST word of the visible ghost.
/// Mid-word ghosts get dictionary completions of the partial word; new-word ghosts get extra model
/// samples. Pure — ranking and insertion text only; `AppDependencies` gathers the candidates and
/// `AlternativesPanel` shows them.
enum WordAlternatives {

    /// Up to `limit` distinct single words from raw candidates, in order: trimmed, cut to their
    /// first word, trailing punctuation removed, empties and `excluding` (case-insensitive) dropped.
    static func rank(_ candidates: [String], excluding: String?, limit: Int) -> [String] {
        var seen = Set(excluding.map { [$0.lowercased()] } ?? [])
        var result: [String] = []
        for raw in candidates {
            guard let word = firstWord(ofGhost: raw) else { continue }
            let cleaned = String(word.reversed().drop { $0.isPunctuation }.reversed())
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
            if result.count == limit { break }
        }
        return result
    }

    /// The first word of a ghost (without its leading space), or nil when it has none.
    static func firstWord(ofGhost ghost: String) -> String? {
        ghost.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// Text to insert after the cursor for `choice`, replacing the ghost's first word.
    /// - New-word ghost (leading space): leading space + choice (+ trailing space).
    /// - Mid-word ghost: `choice` must extend `partialWord` (what's already typed of the word);
    ///   only its missing letters are inserted. nil when it doesn't extend it.
    static func insertion(for choice: String, ghost: String, partialWord: String, trailingSpace: Bool) -> String? {
        let end = trailingSpace ? " " : ""
        if ghost.hasPrefix(" ") || partialWord.isEmpty {
            return (ghost.hasPrefix(" ") ? " " : "") + choice + end
        }
        guard choice.lowercased().hasPrefix(partialWord.lowercased()), choice.count > partialWord.count else {
            return nil
        }
        return String(choice.dropFirst(partialWord.count)) + end
    }
}
