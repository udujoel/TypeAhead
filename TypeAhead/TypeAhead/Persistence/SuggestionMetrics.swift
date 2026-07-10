import Foundation

/// The lifecycle outcome of a single shown suggestion.
///
/// `shown` is recorded once per generation cycle, the first time the overlay paints for that
/// cycle (not on every streamed token update). Exactly one terminal outcome — `accepted`,
/// `rejected`, `dismissed`, or `typedThrough` — normally follows a `shown` event, though the
/// aggregations below don't require pairing; they simply count each kind independently.
enum SuggestionEventKind: String, Codable, Sendable, CaseIterable {
    /// The ghost first painted for this generation cycle.
    case shown
    /// Accepted via Tab — word/ML completion, spell-correction replace, or emoji replace.
    /// See `metadata` for which of the three modes.
    case accepted
    /// A keystroke diverged from the shown ghost (or a new suggestion replaced it) while it
    /// was visible, so the pending suggestion was discarded.
    case rejected
    /// The user pressed Escape to explicitly dismiss the ghost.
    case dismissed
    /// The user typed out the entire ghost character-by-character; it disappeared because
    /// nothing was left to show, not because it was rejected or explicitly accepted via Tab.
    case typedThrough
}

/// One telemetry event: aggregation-safe fields only. Lengths, never full text — full prompt/
/// ghost text is privacy-sensitive and only ever lives in the in-memory debug ring buffer
/// (`SuggestionDebugBuffer`), never persisted here or in `SuggestionEventStore`.
struct SuggestionEvent: Sendable, Equatable {
    var timestamp: Date
    var kind: SuggestionEventKind
    var appName: String
    var bundleID: String
    var modelID: String
    /// Time from the completion pipeline firing (start of `runCompletion`) to first ghost
    /// paint, in milliseconds. Only meaningful on `shown` events; 0 on others.
    var latencyMs: Double
    /// Length of the prompt tail considered for this generation (chars), not the text itself.
    var promptTailLength: Int
    /// Length of the ghost text shown/acted upon (chars), not the text itself.
    var ghostTextLength: Int
    /// Free-form context, e.g. acceptance mode ("word", "spellCorrection", "emoji") on
    /// `accepted` events. Empty string when not applicable.
    var metadata: String

    init(
        timestamp: Date = .now,
        kind: SuggestionEventKind,
        appName: String,
        bundleID: String,
        modelID: String,
        latencyMs: Double = 0,
        promptTailLength: Int = 0,
        ghostTextLength: Int = 0,
        metadata: String = ""
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.appName = appName
        self.bundleID = bundleID
        self.modelID = modelID
        self.latencyMs = latencyMs
        self.promptTailLength = promptTailLength
        self.ghostTextLength = ghostTextLength
        self.metadata = metadata
    }
}

/// Per-app acceptance-rate summary, for the "top N apps" view in Statistics/Diagnostics.
struct AppAcceptanceSummary: Sendable, Equatable {
    var bundleID: String
    var appName: String
    var shown: Int
    var accepted: Int
    var rate: Double
}

/// One day's suggestion volume, for the "suggestions per day" chart.
struct DailySuggestionCount: Sendable, Equatable {
    var day: Date
    var count: Int
}

/// Pure aggregation over `[SuggestionEvent]`. No persistence, no AppKit/SwiftData — safe for
/// SPM unit tests. `SuggestionEventStore` fetches records and maps them into `SuggestionEvent`
/// values that get passed here.
enum SuggestionMetrics {
    /// Overall acceptance rate: accepted / shown. Delegates to `StatisticsCalculator` so the
    /// division-by-zero guard and rounding behavior live in exactly one place.
    static func acceptanceRate(events: [SuggestionEvent]) -> Double {
        let shown = events.filter { $0.kind == .shown }.count
        let accepted = events.filter { $0.kind == .accepted }.count
        return StatisticsCalculator.acceptanceRate(shown: shown, accepted: accepted)
    }

    /// Per-app acceptance rate, sorted by shown-count descending (so callers can `.prefix(5)`
    /// for a "top 5 apps" view). Apps with zero shown events are omitted.
    static func acceptanceRateByApp(events: [SuggestionEvent]) -> [AppAcceptanceSummary] {
        struct Counts { var appName: String; var shown: Int = 0; var accepted: Int = 0 }
        var byBundleID: [String: Counts] = [:]
        for event in events {
            var entry = byBundleID[event.bundleID] ?? Counts(appName: event.appName)
            entry.appName = event.appName  // keep the most-recently-seen display name
            switch event.kind {
            case .shown: entry.shown += 1
            case .accepted: entry.accepted += 1
            default: break
            }
            byBundleID[event.bundleID] = entry
        }
        return byBundleID
            .filter { $0.value.shown > 0 }
            .map { bundleID, counts in
                AppAcceptanceSummary(
                    bundleID: bundleID,
                    appName: counts.appName,
                    shown: counts.shown,
                    accepted: counts.accepted,
                    rate: StatisticsCalculator.acceptanceRate(shown: counts.shown, accepted: counts.accepted)
                )
            }
            .sorted { $0.shown > $1.shown }
    }

    /// Suggestions shown per calendar day (local time zone), sorted oldest-to-newest.
    static func suggestionsPerDay(events: [SuggestionEvent], calendar: Calendar = .current) -> [DailySuggestionCount] {
        var byDay: [Date: Int] = [:]
        for event in events where event.kind == .shown {
            let day = calendar.startOfDay(for: event.timestamp)
            byDay[day, default: 0] += 1
        }
        return byDay
            .map { DailySuggestionCount(day: $0.key, count: $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// Latency P50/P95 in milliseconds, computed over `shown` events only (latency is only
    /// meaningful for events that reached first paint). Returns (0, 0) if there are none.
    static func latencyPercentiles(events: [SuggestionEvent]) -> (p50: Double, p95: Double) {
        let latencies = events.filter { $0.kind == .shown }.map(\.latencyMs)
        return StatisticsCalculator.percentiles(latencies)
    }
}
