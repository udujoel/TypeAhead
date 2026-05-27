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
}
