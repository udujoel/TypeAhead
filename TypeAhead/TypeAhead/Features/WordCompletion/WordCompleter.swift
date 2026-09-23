import AppKit

/// Instant, dictionary-based completion for the word the user is currently mid-typing. Modeled
/// on `TypoDetector` (same `NSSpellChecker` wrapping pattern) — see that file for the
/// `nonisolated(unsafe)` shared-checker rationale (NSSpellChecker is thread-safe in practice and
/// this avoids actor-hopping on the hot keystroke path).
///
/// WP-7: this exists to close the "instant ghost" latency gap — ML inference takes 100s of ms,
/// but a dictionary completion for the word already being typed is ~0ms. The completion this
/// returns is shown through the exact same `OverlayController.showOrUpdateML` call the ML path
/// uses (see `AppDependencies.runCompletion`) — a dictionary word-completion ghost has identical
/// semantics to an ML ghost that continues the current word (no leading space, Tab appends,
/// type-through advances it), so there is no new overlay mode here, just an instant source for
/// the existing one.
enum WordCompleter {
    nonisolated(unsafe) private static let checker = NSSpellChecker.shared

    /// Pure gate: is `partial` eligible for an instant dictionary completion attempt at all?
    /// Mirrors `TypoDetector.correction`'s charset/length guards so dict-completion and
    /// typo-correction stay consistent about what counts as "a word in progress."
    ///
    /// - `>= 3` characters: 2-char partials are too ambiguous (huge candidate fan-out, first
    ///   ranked result would be little better than random).
    /// - Letters and apostrophes only — no digits, punctuation, or `:` (emoji-shortcode) prefix.
    static func shouldOfferInstantCompletion(partial: String?) -> Bool {
        guard let partial, partial.count >= 3 else { return false }
        return partial.allSatisfy { $0.isLetter || $0 == "'" }
    }

    /// Best dictionary completion for the partial word the user is mid-typing, as the SUFFIX to
    /// append (remaining letters only) — or nil when there's no confident one.
    ///
    /// Uses the same `completions(forPartialWordRange:in:language:inSpellDocumentWithTag:)` API
    /// `TypoDetector.isPrefixOfValidWord` uses, which returns candidates pre-ranked by
    /// NSSpellChecker; this takes the first candidate that is a strict, case-insensitive prefix
    /// extension of `partial` (filtering out fuzzy/unrelated suggestions the API can also return).
    ///
    /// Casing: the comparison against `partial` is case-insensitive, and the returned suffix is
    /// whatever characters remain on the *candidate* after dropping `partial.count` characters —
    /// so if the candidate's own casing diverges from what the user typed (e.g. a candidate
    /// capitalized differently mid-word), the suffix reflects the candidate's casing verbatim.
    /// This is documented, not "fixed" — see `WordCompleterTests` for actual observed behavior.
    static func completionSuffix(forPartial partial: String, language: String? = nil) -> String? {
        guard let completions = checker.completions(
            forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
            in: partial,
            language: language ?? checker.language(),
            inSpellDocumentWithTag: 0
        ) else { return nil }

        let lower = partial.lowercased()
        guard let candidate = completions.first(where: { candidate in
            let candidateLower = candidate.lowercased()
            return candidateLower.hasPrefix(lower) && candidateLower != lower
        }) else { return nil }

        return String(candidate.dropFirst(partial.count))
    }
}
