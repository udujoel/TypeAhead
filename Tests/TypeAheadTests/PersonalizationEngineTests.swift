import Testing
@testable import TypeAhead

@Suite struct PersonalizationEngineTests {
    @Test func returnsEmptyAtZeroStrength() async {
        let engine = await PersonalizationEngine(historyStore: HistoryStore(inMemory: true))
        let examples = await engine.examples(strength: 0.0, limit: 5)
        #expect(examples.isEmpty)
    }

    @Test func returnsExamplesAtNonZeroStrength() async throws {
        let store = await HistoryStore(inMemory: true)
        try await store.record(accepted: "Therefore I am", appName: "Notes")
        let engine = await PersonalizationEngine(historyStore: store)
        let examples = await engine.examples(strength: 0.5, limit: 5)
        #expect(!examples.isEmpty)
    }

    @Test func limitsExamplesByStrength() async throws {
        let store = await HistoryStore(inMemory: true)
        for i in 0..<10 {
            try await store.record(accepted: "phrase \(i)", appName: "Mail")
        }
        let engine = await PersonalizationEngine(historyStore: store)
        let atMax = await engine.examples(strength: 1.0, limit: 10)
        let atHalf = await engine.examples(strength: 0.5, limit: 10)
        #expect(atMax.count >= atHalf.count)
    }
}
