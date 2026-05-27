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

    func deleteAll() throws {
        let context = container.mainContext
        try context.delete(model: HistoryRecord.self)
        try context.save()
    }
}
