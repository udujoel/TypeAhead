import SwiftData
import Foundation

@MainActor
final class HistoryStore {
    private let container: ModelContainer

    init(inMemory: Bool = false) {
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            // Store under an app-namespaced path (CLAUDE.md: "~/Library/Application
            // Support/TypeAhead/history.db"), not SwiftData's un-namespaced default
            // ("~/Library/Application Support/default.store") — with no sandbox, that
            // default location is a bare filename any other SwiftData app on the Mac
            // could collide with.
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TypeAhead", isDirectory: true)
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let storeURL = supportDir.appendingPathComponent("history.db")
            config = ModelConfiguration(url: storeURL)
        }
        container = try! ModelContainer(for: HistoryRecord.self, configurations: config)
        if !inMemory {
            Self.restrictPermissions(config: config)
        }
    }

    /// The history store holds no real encryption (plain SwiftData/SQLite — see CLAUDE.md), so
    /// as a minimal at-rest hardening step, restrict the on-disk file(s) to owner read/write
    /// only (0600) right after the container creates them. Best-effort: failure here doesn't
    /// prevent the app from working, just leaves the default (looser) file permissions.
    private static func restrictPermissions(config: ModelConfiguration) {
        guard let url = config.url as URL? else { return }
        let fm = FileManager.default
        // SQLite stores as up to three files on disk: the main store, "-wal", and "-shm".
        let candidates = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        for fileURL in candidates where fm.fileExists(atPath: fileURL.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
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
