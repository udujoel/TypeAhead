import Testing
import SwiftData
@testable import TypeAhead

@Suite struct HistoryStoreTests {
    @Test func insertsAndRetrievesRecord() async throws {
        let store = await HistoryStore(inMemory: true)
        try await store.record(accepted: "hello world", appName: "Notes")
        let phrases = await store.recentAcceptedPhrases(limit: 10)
        #expect(phrases.contains("hello world"))
    }

    @Test func respectsLimit() async throws {
        let store = await HistoryStore(inMemory: true)
        for i in 0..<10 {
            try await store.record(accepted: "phrase \(i)", appName: "Mail")
        }
        let phrases = await store.recentAcceptedPhrases(limit: 5)
        #expect(phrases.count == 5)
    }

    @Test func deletesAllHistory() async throws {
        let store = await HistoryStore(inMemory: true)
        try await store.record(accepted: "test", appName: "Notes")
        try await store.deleteAll()
        let phrases = await store.recentAcceptedPhrases(limit: 10)
        #expect(phrases.isEmpty)
    }

    // MARK: - frequentAcceptedPhrases

    @Test func frequentPhrasesRanksHigherCountFirst() async throws {
        let store = await HistoryStore(inMemory: true)
        // "happy" accepted 3x, "sad" accepted once → "happy" should rank higher
        for _ in 0..<3 { try await store.record(accepted: "happy", appName: "Notes") }
        try await store.record(accepted: "sad", appName: "Notes")
        let phrases = await store.frequentAcceptedPhrases(limit: 5)
        #expect(phrases.first == "happy")
    }

    @Test func frequentPhrasesDeduplicatesCase() async throws {
        let store = await HistoryStore(inMemory: true)
        // Same word, different cases — should merge to one entry.
        try await store.record(accepted: "Hello", appName: "Notes")
        try await store.record(accepted: "hello", appName: "Notes")
        let phrases = await store.frequentAcceptedPhrases(limit: 5)
        #expect(phrases.count == 1)
    }

    @Test func frequentPhrasesReturnsEmptyWhenNoHistory() async {
        let store = await HistoryStore(inMemory: true)
        let phrases = await store.frequentAcceptedPhrases(limit: 5)
        #expect(phrases.isEmpty)
    }

    @Test func frequentPhrasesRespectLimit() async throws {
        let store = await HistoryStore(inMemory: true)
        for i in 0..<10 {
            try await store.record(accepted: "word\(i)", appName: "Notes")
        }
        let phrases = await store.frequentAcceptedPhrases(limit: 3)
        #expect(phrases.count <= 3)
    }
}
