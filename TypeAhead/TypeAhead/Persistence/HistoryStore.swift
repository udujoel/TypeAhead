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
    ///
    /// Deduplication is case-insensitive (so "SwiftUI" and "swiftui" merge into one bucket),
    /// but the returned string preserves the **most-recently accepted canonical spelling** —
    /// so the persona prompt sees "SwiftUI", not "swiftui".
    func frequentAcceptedPhrases(limit: Int) async -> [String] {
        let context = container.mainContext
        // Fetch a larger window so low-frequency but highly-recent words don't always win.
        var descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit * 20, 200)
        guard let records = try? context.fetch(descriptor) else { return [] }

        // Group by lowercase key; track count, latest timestamp, and the canonical (original)
        // spelling from the most-recent acceptance. This preserves "SwiftUI" over "swiftui".
        struct Entry { var count: Int; var latest: Date; var canonical: String }
        var seen: [String: Entry] = [:]
        for record in records {
            let trimmed = record.acceptedText.trimmingCharacters(in: .whitespaces)
            let key = trimmed.lowercased()
            guard !key.isEmpty else { continue }
            if let existing = seen[key] {
                // Update canonical to the more-recently accepted spelling.
                let newerCanonical = record.timestamp > existing.latest ? trimmed : existing.canonical
                seen[key] = Entry(
                    count: existing.count + 1,
                    latest: max(existing.latest, record.timestamp),
                    canonical: newerCanonical
                )
            } else {
                seen[key] = Entry(count: 1, latest: record.timestamp, canonical: trimmed)
            }
        }

        // Sort descending: primary = count, secondary = recency.
        let sorted = seen.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.latest > $1.latest
        }

        return Array(sorted.prefix(limit).map(\.canonical))
    }

    /// Total number of accepted-word records stored (for the Settings "collected so far" badge).
    func recordCount() async -> Int {
        let context = container.mainContext
        let descriptor = FetchDescriptor<HistoryRecord>()
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    func deleteAll() throws {
        let context = container.mainContext
        try context.delete(model: HistoryRecord.self)
        try context.save()
    }
}
