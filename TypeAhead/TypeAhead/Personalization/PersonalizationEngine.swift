import Foundation

@MainActor
final class PersonalizationEngine {
    private let historyStore: HistoryStore

    init(historyStore: HistoryStore) {
        self.historyStore = historyStore
    }

    /// Returns up to `limit` phrase examples from history, scaled by `strength` (0–1).
    /// Uses frequency-weighted lookup so commonly-accepted words rank higher than one-offs.
    func examples(strength: Double, limit: Int) async -> [String] {
        guard strength > 0 else { return [] }
        let maxExamples = max(1, Int((Double(limit) * strength).rounded()))
        return await historyStore.frequentAcceptedPhrases(limit: maxExamples)
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
    /// - Parameters:
    ///   - customInstructions: User's freeform role/domain description from Settings.
    ///   - examples: Recent frequent words/phrases from HistoryStore (already fetched).
    /// - Returns: A concise persona clause to prepend to the base instruction, or nil.
    nonisolated static func buildPersonaNote(customInstructions: String, examples: [String]) -> String? {
        var parts: [String] = []

        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Limit to 400 chars so a long custom instruction doesn't balloon the prompt.
            let capped = trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
            parts.append(capped)
        }

        if !examples.isEmpty {
            // Surface frequently accepted words as a stylistic hint, not a list to echo.
            let joined = examples.prefix(5).joined(separator: ", ")
            parts.append("Words the user often accepts: \(joined).")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }
}
