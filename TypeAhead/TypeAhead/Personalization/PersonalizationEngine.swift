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
    /// without importing MLXLLM. `nonisolated` — pure constant, no actor state.
    nonisolated static let baseInstruction =
        "Continue the text the user is writing. Reply with only the next few words that come "
        + "naturally, matching their wording and style. Do not repeat what they already wrote, "
        + "and do not add quotes, labels, or explanations."

    /// Builds the full system instruction: optional persona prefix + base instruction.
    /// `nonisolated` — pure computation, no actor state.
    nonisolated static func buildInstruction(personaNote: String?) -> String {
        guard let note = personaNote, !note.isEmpty else { return baseInstruction }
        return "\(note)\n\n\(baseInstruction)"
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
