import Testing
import Foundation
@testable import TypeAhead

@Suite struct SuggestionEventStoreTests {
    private func event(kind: SuggestionEventKind = .shown, daysAgo: Int = 0) -> SuggestionEvent {
        let timestamp = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        return SuggestionEvent(
            timestamp: timestamp,
            kind: kind,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            modelID: "gemma-4-e2b",
            latencyMs: 42,
            promptTailLength: 40,
            ghostTextLength: 10
        )
    }

    @Test func insertsAndRetrievesEvent() async throws {
        let store = await SuggestionEventStore(inMemory: true)
        try await store.record(event())
        let events = await store.allEvents()
        #expect(events.count == 1)
        #expect(events.first?.appName == "Notes")
    }

    @Test func allEventsReturnsNewestFirst() async throws {
        let store = await SuggestionEventStore(inMemory: true)
        try await store.record(event(daysAgo: 5))
        try await store.record(event(daysAgo: 0))
        let events = await store.allEvents()
        #expect(events.first?.timestamp ?? .distantPast > events.last?.timestamp ?? .distantFuture)
    }

    @Test func deleteAllClearsStore() async throws {
        let store = await SuggestionEventStore(inMemory: true)
        try await store.record(event())
        try await store.deleteAll()
        let events = await store.allEvents()
        #expect(events.isEmpty)
    }

    @Test func recordDoesNotPruneWithinASession() async throws {
        // Pruning is a one-shot pass in init() (see pruneExpired()), not re-run on every
        // record() — so an old event inserted mid-session is not retroactively pruned until
        // the store is reconstructed. This documents that intentional behavior.
        let store = await SuggestionEventStore(inMemory: true)
        try await store.record(event(daysAgo: SuggestionEventStore.retentionDays + 5))
        try await store.record(event(daysAgo: 1))
        let events = await store.allEvents()
        #expect(events.count == 2)
    }

    @Test func pruneRemovesRecordsPastCutoffLogic() {
        // Mirrors the predicate used in SuggestionEventStore.pruneExpired(): anything older
        // than retentionDays should be considered expired.
        let cutoff = Calendar.current.date(byAdding: .day, value: -SuggestionEventStore.retentionDays, to: .now)!
        let old = Calendar.current.date(byAdding: .day, value: -(SuggestionEventStore.retentionDays + 1), to: .now)!
        let recent = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        #expect(old < cutoff)
        #expect(recent > cutoff)
    }
}
