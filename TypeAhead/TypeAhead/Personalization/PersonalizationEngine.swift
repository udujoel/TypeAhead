import Foundation

@MainActor
final class PersonalizationEngine {
    private let historyStore: HistoryStore

    init(historyStore: HistoryStore) {
        self.historyStore = historyStore
    }

    /// Returns up to `limit` phrase examples from history, scaled by `strength` (0–1).
    /// Uses frequency-weighted lookup so commonly-accepted words rank higher than one-offs.
    /// Short fragments (< 4 chars) and single-char suffixes are filtered out so accidental
    /// tab-accepts of word fragments (e.g. "ried", "to") don't pollute the persona note.
    func examples(strength: Double, limit: Int) async -> [String] {
        guard strength > 0 else { return [] }
        // Fetch extra headroom to account for filtering.
        let maxExamples = max(1, Int((Double(limit) * strength).rounded()))
        let all = await historyStore.frequentAcceptedPhrases(limit: maxExamples * 4)
        let filtered = all.filter { Self.isUsableExample($0) }
        return Array(filtered.prefix(maxExamples))
    }

    /// Returns true when a history phrase is suitable as a persona example.
    ///
    /// Rejects fragments that are too short to be meaningful vocabulary markers —
    /// "ried" (4), "tion" (4), "to" (2), "it" (2) are all ≤ 4 chars and likely
    /// came from accidental partial-word accepts. Real vocabulary words like
    /// "SwiftUI" (7), "however" (7), "Python" (6) are all ≥ 5 chars.
    /// Also rejects strings made entirely of punctuation/whitespace.
    nonisolated static func isUsableExample(_ phrase: String) -> Bool {
        let s = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 5 else { return false }
        // Must contain at least one letter (exclude pure numbers/punctuation).
        return s.contains(where: { $0.isLetter })
    }

    // MARK: - System instruction building (pure, testable without MLXLLM)

    /// The base system instruction given to the model on every completion.
    /// Kept here (not in InferenceEngine) so it's accessible to SPM unit tests
    /// without importing MLXLLM. `nonisolated` — pure function, no actor state.
    ///
    /// WP-B (aggressive, persistent suggestions): earlier wording ("Reply with only the next
    /// few words") was too soft — the model happily replied with '.', '...', or an empty line,
    /// which collapses to ghost="" and nothing shows. This firms up the instruction with an
    /// explicit word-count target and an outright ban on punctuation-only/empty replies, so a
    /// suggestion is expected on every cycle, not just the ones where the model felt like it.
    ///
    /// WP-6 (mid-word completion): added the "middle of a word" sentence so the model completes
    /// a word the user is still typing ("he" -> "lp") instead of always jumping ahead to a new
    /// word. This is STATIC text, not the actual partial word — the instruction is the FIRST
    /// part of the prompt token sequence the KV-cache (WS6, see PromptCacheValidity) is keyed
    /// on, so embedding per-keystroke dynamic text here (e.g. "complete 'he'") would change
    /// token 0 on every keystroke and force a full cache rebuild every cycle, defeating cache
    /// reuse entirely. A fixed sentence, byte-identical every cycle, keeps the cache warm.
    ///
    /// - Parameter targetWords: the user's configured completion length
    ///   (`settings.completionLength.maxWords`) — the model is told to produce between 2 and
    ///   this many words. Threaded in by `InferenceEngine.complete` as its own `maxWords`
    ///   parameter (the same value that later clamps the displayed ghost via `GhostText`), so
    ///   the instruction and the display cap always agree. `targetWords < 2` (i.e.
    ///   `CompletionLength.short`, maxWords == 1) gets its own sentence — "at least 2 and at
    ///   most 1 words" is self-contradictory — while every other value keeps the exact
    ///   byte-identical range sentence.
    ///
    /// `britishSpelling` swaps one static sentence (it changes only when the setting does, so the
    /// KV cache keyed on this instruction still reuses across keystrokes); false keeps the text
    /// byte-identical to before the English-variant setting existed.
    nonisolated static func baseInstruction(targetWords: Int, britishSpelling: Bool = false) -> String {
        let lengthSentence = targetWords < 2
            ? "Always continue with exactly one word that comes naturally, matching their "
            + "wording and style."
            : "Always continue with at least 2 and at most \(targetWords) words that come "
            + "naturally, matching their wording and style."
        return "Continue the text the user is writing. " + lengthSentence + " If the "
        + "text ends in the middle of a word, first finish that exact word (output only its "
        + "remaining letters, with no space before them), then continue with the following "
        + "words. " + (britishSpelling
            ? "Write only in English, using British spelling (colour, organise, centre). "
            : "Write only in English. ")
        + "Never reply with only punctuation, an ellipsis, or an "
        + "empty line — always predict the most likely next words. Do not repeat words they "
        + "already completed, and do not add quotes, labels, or explanations."
    }

    /// Defensive re-cap for the suffix hint appended to the instruction. `ContextBuilder.buildSuffix`
    /// already caps at this many chars, but the instruction builder shouldn't trust that from a
    /// distance — re-cap here so a future caller can't blow up the prompt.
    nonisolated private static let maxSuffixHintChars = 120

    /// Builds the full system instruction: optional persona prefix + base instruction +
    /// optional suffix hint. `nonisolated` — pure computation, no actor state.
    ///
    /// - Parameter suffix: text already after the cursor (from `ContextBuilder.buildSuffix`).
    ///   When non-empty, appended as an instruction-level hint so the model knows what follows
    ///   the cursor and avoids duplicating/contradicting it — WITHOUT touching the assistant-prefill
    ///   seed itself (that must stay exactly the user's prefix; see InferenceEngine/HFBridge).
    ///   Empty suffix (the common "cursor at end of text" case) leaves the instruction
    ///   byte-identical to the no-suffix behavior.
    /// - Parameter targetWords: forwarded to `baseInstruction(targetWords:)` — see its doc
    ///   comment. Structural composition here (persona prefix, suffix hint) is unchanged from
    ///   before WP-B; only `baseInstruction`'s own text now varies with this value.
    nonisolated static func buildInstruction(
        personaNote: String?, suffix: String = "", targetWords: Int, britishSpelling: Bool = false
    ) -> String {
        let core = baseInstruction(targetWords: targetWords, britishSpelling: britishSpelling)
        let base: String
        if let note = personaNote, !note.isEmpty {
            base = "\(note)\n\n\(core)"
        } else {
            base = core
        }

        let cappedSuffix = String(suffix.prefix(maxSuffixHintChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cappedSuffix.isEmpty else { return base }

        return base
            + "\n\nThe text after the cursor continues: \"\(cappedSuffix)\" — your completion "
            + "must lead into it naturally and must not repeat it."
    }

    /// Builds the personalized system instruction to inject into InferenceEngine.
    /// Returns nil when nothing is configured (saves tokens when personalization is off).
    ///
    /// Format notes:
    /// - Custom instructions are user prose (first, so they're most prominent).
    /// - `appStyleInstruction` is the focused app's per-app style override (e.g. "Mail:
    ///   professional", "Slack: casual") from `AppPolicyResolver` — appended after custom
    ///   instructions so it can refine/override the general persona for this specific app.
    /// - History examples use a bracket/pipe format (NOT a prose sentence) to reduce the
    ///   chance that a small model echoes them as text to generate. A sentence like
    ///   "Words the user often accepts: X, Y." looks continuable — small models generate
    ///   it verbatim. The bracket format signals metadata, not text.
    /// - The combined note (all sources together) is capped to ~200 chars so per-app style
    ///   instructions can't balloon the prompt for small models — a tighter budget than the
    ///   400-char per-field cap below, which only bounds an individual source.
    nonisolated static func buildPersonaNote(
        customInstructions: String,
        examples: [String],
        appStyleInstruction: String? = nil
    ) -> String? {
        var parts: [String] = []

        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Limit to 400 chars so a long custom instruction doesn't balloon the prompt.
            let capped = trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
            parts.append(capped)
        }

        if let style = appStyleInstruction?.trimmingCharacters(in: .whitespacesAndNewlines), !style.isEmpty {
            parts.append(style)
        }

        if !examples.isEmpty {
            // Bracket format — looks like metadata, not a sentence small models will echo.
            // "Words the user often accepts: X." was being output verbatim by the model.
            let joined = examples.prefix(5).joined(separator: " | ")
            parts.append("[style: \(joined)]")
        }

        guard !parts.isEmpty else { return nil }
        let combined = parts.joined(separator: "\n")
        guard combined.count > 200 else { return combined }
        return String(combined.prefix(200)) + "…"
    }
}
