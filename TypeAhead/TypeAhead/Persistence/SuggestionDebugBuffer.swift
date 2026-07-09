import Foundation

/// Full-detail record of one suggestion, for the in-memory Diagnostics pane only.
///
/// Unlike `SuggestionEvent` (which stores only lengths for privacy), this holds the actual
/// prompt tail and ghost text — but it is NEVER persisted to disk. `SuggestionDebugBuffer`
/// keeps only the most recent entries in memory and they're gone on quit.
struct SuggestionDebugEntry: Sendable, Equatable, Identifiable {
    var id = UUID()
    var timestamp: Date
    var kind: SuggestionEventKind
    var appName: String
    /// Last 40 chars of the prompt before the cursor — enough to see context, capped to keep
    /// this from becoming a de facto keystroke log.
    var promptTail: String
    var ghostText: String
    var latencyMs: Double
    var metadata: String

    init(
        timestamp: Date = .now,
        kind: SuggestionEventKind,
        appName: String,
        promptTail: String,
        ghostText: String,
        latencyMs: Double = 0,
        metadata: String = ""
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.appName = appName
        self.promptTail = String(promptTail.suffix(40))
        self.ghostText = ghostText
        self.latencyMs = latencyMs
        self.metadata = metadata
    }
}

/// Fixed-capacity ring buffer of the most recent suggestion detail, newest first.
///
/// Pure/in-memory: no persistence, no AppKit/SwiftData dependency, so it's safe to unit test
/// under SPM. `AppDependencies` owns one instance and the Diagnostics settings pane reads it.
final class SuggestionDebugBuffer: @unchecked Sendable {
    private let capacity: Int
    private var entries: [SuggestionDebugEntry] = []
    private let lock = NSLock()

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    func record(_ entry: SuggestionDebugEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    /// Newest-first snapshot of the buffer's current contents.
    var recent: [SuggestionDebugEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
