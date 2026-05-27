import Foundation

@MainActor
final class PersonalizationEngine {
    private let historyStore: HistoryStore

    init(historyStore: HistoryStore) {
        self.historyStore = historyStore
    }

    func examples(strength: Double, limit: Int) async -> [String] {
        guard strength > 0 else { return [] }
        let maxExamples = Int((Double(limit) * strength).rounded())
        return await historyStore.recentAcceptedPhrases(limit: maxExamples)
    }
}
