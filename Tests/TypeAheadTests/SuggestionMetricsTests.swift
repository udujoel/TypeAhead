import Testing
import Foundation
@testable import TypeAhead

@Suite struct SuggestionMetricsTests {
    private func event(
        kind: SuggestionEventKind,
        appName: String = "Notes",
        bundleID: String = "com.apple.Notes",
        latencyMs: Double = 0,
        daysAgo: Int = 0
    ) -> SuggestionEvent {
        let timestamp = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        return SuggestionEvent(
            timestamp: timestamp,
            kind: kind,
            appName: appName,
            bundleID: bundleID,
            modelID: "gemma-4-e2b",
            latencyMs: latencyMs,
            promptTailLength: 40,
            ghostTextLength: 10
        )
    }

    // MARK: - acceptanceRate

    @Test func acceptanceRateIsZeroWithNoEvents() {
        #expect(SuggestionMetrics.acceptanceRate(events: []) == 0)
    }

    @Test func acceptanceRateCountsShownVsAccepted() {
        let events = [event(kind: .shown), event(kind: .shown), event(kind: .accepted)]
        #expect(SuggestionMetrics.acceptanceRate(events: events) == 0.5)
    }

    @Test func acceptanceRateIgnoresNonShownNonAcceptedKinds() {
        let events = [event(kind: .shown), event(kind: .rejected), event(kind: .dismissed), event(kind: .typedThrough)]
        #expect(SuggestionMetrics.acceptanceRate(events: events) == 0)
    }

    // MARK: - acceptanceRateByApp

    @Test func acceptanceRateByAppGroupsByBundleID() {
        let events = [
            event(kind: .shown, appName: "Notes", bundleID: "com.apple.Notes"),
            event(kind: .accepted, appName: "Notes", bundleID: "com.apple.Notes"),
            event(kind: .shown, appName: "Mail", bundleID: "com.apple.Mail"),
        ]
        let summary = SuggestionMetrics.acceptanceRateByApp(events: events)
        #expect(summary.count == 2)
        let notes = summary.first { $0.bundleID == "com.apple.Notes" }
        #expect(notes?.shown == 1)
        #expect(notes?.accepted == 1)
        #expect(notes?.rate == 1.0)
    }

    @Test func acceptanceRateByAppSortsByShownDescending() {
        let events = [
            event(kind: .shown, bundleID: "com.a"),
            event(kind: .shown, bundleID: "com.b"),
            event(kind: .shown, bundleID: "com.b"),
            event(kind: .shown, bundleID: "com.b"),
        ]
        let summary = SuggestionMetrics.acceptanceRateByApp(events: events)
        #expect(summary.first?.bundleID == "com.b")
    }

    @Test func acceptanceRateByAppOmitsAppsWithNoShownEvents() {
        // A rejected/dismissed-only app (edge case; shouldn't normally happen without a
        // preceding shown, but the aggregator should not surface a shown=0 row).
        let events = [event(kind: .rejected, bundleID: "com.c")]
        let summary = SuggestionMetrics.acceptanceRateByApp(events: events)
        #expect(summary.isEmpty)
    }

    // MARK: - suggestionsPerDay

    @Test func suggestionsPerDayGroupsByCalendarDay() {
        let events = [
            event(kind: .shown, daysAgo: 0),
            event(kind: .shown, daysAgo: 0),
            event(kind: .shown, daysAgo: 1),
        ]
        let perDay = SuggestionMetrics.suggestionsPerDay(events: events)
        #expect(perDay.count == 2)
        #expect(perDay.reduce(0) { $0 + $1.count } == 3)
    }

    @Test func suggestionsPerDaySortsOldestFirst() {
        let events = [event(kind: .shown, daysAgo: 0), event(kind: .shown, daysAgo: 3)]
        let perDay = SuggestionMetrics.suggestionsPerDay(events: events)
        #expect(perDay.first!.day < perDay.last!.day)
    }

    @Test func suggestionsPerDayIgnoresNonShownEvents() {
        let events = [event(kind: .accepted), event(kind: .dismissed)]
        #expect(SuggestionMetrics.suggestionsPerDay(events: events).isEmpty)
    }

    // MARK: - latencyPercentiles

    @Test func latencyPercentilesReturnsZeroWithNoShownEvents() {
        let (p50, p95) = SuggestionMetrics.latencyPercentiles(events: [])
        #expect(p50 == 0)
        #expect(p95 == 0)
    }

    @Test func latencyPercentilesOnlyUsesShownEvents() {
        let events = [
            event(kind: .shown, latencyMs: 100),
            event(kind: .accepted, latencyMs: 9999),  // must be excluded
        ]
        let (p50, _) = SuggestionMetrics.latencyPercentiles(events: events)
        #expect(p50 == 100)
    }

    @Test func latencyPercentilesComputesAcrossMultipleShownEvents() {
        let events = (1...10).map { event(kind: .shown, latencyMs: Double($0) * 10) }
        let (p50, p95) = SuggestionMetrics.latencyPercentiles(events: events)
        #expect(p50 > 0)
        #expect(p95 >= p50)
    }
}
