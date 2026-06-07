import SwiftData
import Foundation

@MainActor
final class HistoryStore {
    private let container: ModelContainer

    init(inMemory: Bool = false) {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try! ModelContainer(for: HistoryRecord.self, configurations: config)
    }

    func record(accepted text: String, appName: String) throws {
        let context = container.mainContext
        let record = HistoryRecord(acceptedText: text, appName: appName)
        context.insert(record)
        try context.save()
    }

    func recentAcceptedPhrases(limit: Int) async -> [String] {
        let context = container.mainContext
        var descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let records = try? context.fetch(descriptor)
        return records?.map(\.acceptedText) ?? []
    }

    /// Returns up to `limit` phrases weighted by frequency × recency.
    /// More-used words bubble up; recently used words are preferred within the same count.
    /// This is the basis for the personalization few-shot examples injected into the prompt.
    func frequentAcceptedPhrases(limit: Int) async -> [String] {
        let context = container.mainContext
        // Fetch a larger window so low-frequency but highly-recent words don't always win.
        var descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit * 20, 200)
        guard let records = try? context.fetch(descriptor) else { return [] }

        // Group by phrase, tracking count and most-recent timestamp.
        var seen: [String: (count: Int, latest: Date)] = [:]
        for record in records {
            let key = record.acceptedText.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if let existing = seen[key] {
                seen[key] = (existing.count + 1, max(existing.latest, record.timestamp))
            } else {
                seen[key] = (1, record.timestamp)
            }
        }

        // Sort descending: primary = count, secondary = recency.
        let sorted = seen.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return $0.value.latest > $1.value.latest
        }

        return Array(sorted.prefix(limit).map(\.key))
    }

    func deleteAll() throws {
        let context = container.mainContext
        try context.delete(model: HistoryRecord.self)
        try context.save()
    }
}
