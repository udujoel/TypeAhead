import SwiftUI

struct StatisticsView: View {
    @State private var keystrokesSaved = 0
    @State private var acceptanceRate: Double = 0
    @State private var latencyP50: Double = 0
    @State private var latencyP95: Double = 0
    @State private var suggestionsPerDay: [DailySuggestionCount] = []
    @State private var topApps: [AppAcceptanceSummary] = []

    private let historyStore = AppDependencies.shared.historyStore
    private let eventStore = AppDependencies.shared.eventStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    statCard(title: "Keystrokes Saved", value: "\(keystrokesSaved)")
                    statCard(title: "Acceptance Rate", value: "\(Int((acceptanceRate * 100).rounded()))%")
                    statCard(title: "Suggestions/Day", value: averagePerDayLabel)
                }
                HStack(spacing: 24) {
                    statCard(title: "Latency P50", value: "\(Int(latencyP50.rounded()))ms")
                    statCard(title: "Latency P95", value: "\(Int(latencyP95.rounded()))ms")
                }

                if !topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Apps by Acceptance Rate")
                            .font(.headline)
                        ForEach(topApps.prefix(5), id: \.bundleID) { app in
                            HStack {
                                Text(app.appName)
                                Spacer()
                                Text("\(app.accepted)/\(app.shown) shown")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(Int((app.rate * 100).rounded()))%")
                                    .bold()
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .navigationTitle("Statistics")
        .task {
            let phrases = await historyStore.recentAcceptedPhrases(limit: 1000)
            keystrokesSaved = StatisticsCalculator.keystrokesSaved(from: phrases)

            let events = await eventStore.allEvents()
            acceptanceRate = SuggestionMetrics.acceptanceRate(events: events)
            let (p50, p95) = SuggestionMetrics.latencyPercentiles(events: events)
            latencyP50 = p50
            latencyP95 = p95
            suggestionsPerDay = SuggestionMetrics.suggestionsPerDay(events: events)
            topApps = SuggestionMetrics.acceptanceRateByApp(events: events)
        }
    }

    private var averagePerDayLabel: String {
        guard !suggestionsPerDay.isEmpty else { return "0" }
        let total = suggestionsPerDay.reduce(0) { $0 + $1.count }
        let average = Double(total) / Double(suggestionsPerDay.count)
        return "\(Int(average.rounded()))"
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold()
        }
        .padding()
        .frame(minWidth: 120)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
