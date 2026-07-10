import SwiftData
import Foundation

/// SwiftData-backed store for `SuggestionEventRecord`, following `HistoryStore`'s exact
/// pattern: app-namespaced store URL, 0600 hardening, `inMemory:` for tests.
///
/// Retention: capped at 30 days AND 20k events — whichever is more restrictive prunes first,
/// checked once on init so the store never grows unbounded across a long-running install.
@MainActor
final class SuggestionEventStore {
    private let container: ModelContainer

    nonisolated static let retentionDays = 30
    nonisolated static let retentionMaxEvents = 20_000

    init(inMemory: Bool = false) {
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            // Namespaced under Application Support/TypeAhead, same as history.db — see
            // HistoryStore for why (avoid SwiftData's un-namespaced default.store).
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TypeAhead", isDirectory: true)
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let storeURL = supportDir.appendingPathComponent("suggestion_events.db")
            config = ModelConfiguration(url: storeURL)
        }
        container = try! ModelContainer(for: SuggestionEventRecord.self, configurations: config)
        if !inMemory {
            Self.restrictPermissions(config: config)
        }
        pruneExpired()
    }

    /// Same at-rest hardening as `HistoryStore`: no real encryption, so restrict the on-disk
    /// SQLite file(s) to owner read/write only.
    private static func restrictPermissions(config: ModelConfiguration) {
        guard let url = config.url as URL? else { return }
        let fm = FileManager.default
        let candidates = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        for fileURL in candidates where fm.fileExists(atPath: fileURL.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    func record(_ event: SuggestionEvent) throws {
        let context = container.mainContext
        let record = SuggestionEventRecord(
            timestamp: event.timestamp,
            kind: event.kind,
            appName: event.appName,
            bundleID: event.bundleID,
            modelID: event.modelID,
            latencyMs: event.latencyMs,
            promptTailLength: event.promptTailLength,
            ghostTextLength: event.ghostTextLength,
            metadata: event.metadata
        )
        context.insert(record)
        try context.save()
    }

    /// All events, newest first. Used by the pure `SuggestionMetrics` aggregators and the
    /// Statistics/Diagnostics views.
    func allEvents() async -> [SuggestionEvent] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SuggestionEventRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map(\.asEvent)
    }

    func deleteAll() throws {
        let context = container.mainContext
        try context.delete(model: SuggestionEventRecord.self)
        try context.save()
    }

    /// Prunes anything older than `retentionDays`, then — if still over `retentionMaxEvents`
    /// — trims the oldest excess so the store stays bounded. Runs once on init.
    private func pruneExpired() {
        let context = container.mainContext
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: .now) ?? .distantPast
        let expiredDescriptor = FetchDescriptor<SuggestionEventRecord>(
            predicate: #Predicate { $0.timestamp < cutoff }
        )
        if let expired = try? context.fetch(expiredDescriptor) {
            for record in expired { context.delete(record) }
        }

        let countDescriptor = FetchDescriptor<SuggestionEventRecord>()
        let total = (try? context.fetchCount(countDescriptor)) ?? 0
        if total > Self.retentionMaxEvents {
            var oldestFirst = FetchDescriptor<SuggestionEventRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .forward)]
            )
            oldestFirst.fetchLimit = total - Self.retentionMaxEvents
            if let excess = try? context.fetch(oldestFirst) {
                for record in excess { context.delete(record) }
            }
        }

        try? context.save()
    }
}
