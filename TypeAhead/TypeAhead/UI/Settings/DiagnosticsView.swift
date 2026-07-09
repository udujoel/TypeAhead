import SwiftUI

/// "Recent Suggestions" debug pane (WS2): the last 50 suggestions in full detail — prompt
/// tail, ghost text, outcome, latency, app — read from the in-memory `SuggestionDebugBuffer`
/// (never persisted; see CLAUDE.md privacy rules). Also surfaces the same aggregate stats as
/// Statistics, sourced from the persisted `SuggestionEventStore` via the pure `SuggestionMetrics`
/// aggregators, so this pane doubles as a quick sanity check without leaving Settings.
struct DiagnosticsView: View {
    private let deps = AppDependencies.shared
    @State private var entries: [SuggestionDebugEntry] = []
    @State private var acceptanceRate: Double = 0
    @State private var latencyP50: Double = 0
    @State private var latencyP95: Double = 0

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    statCard(title: "Acceptance Rate", value: "\(Int((acceptanceRate * 100).rounded()))%")
                    statCard(title: "Latency P50", value: "\(Int(latencyP50.rounded()))ms")
                    statCard(title: "Latency P95", value: "\(Int(latencyP95.rounded()))ms")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Suggestions")
                        .font(.headline)
                    Text("Last \(entries.count) suggestions, newest first. In-memory only — cleared on quit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if entries.isEmpty {
                        Text("No suggestions yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        recentSuggestionsTable
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Diagnostics")
        .task { await refresh() }
    }

    private var recentSuggestionsTable: some View {
        Table(entries) {
            TableColumn("Time") { entry in
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(.caption, design: .monospaced))
            }
            .width(70)
            TableColumn("App") { entry in
                Text(entry.appName)
            }
            .width(100)
            TableColumn("Outcome") { entry in
                Text(outcomeLabel(entry.kind))
                    .foregroundStyle(outcomeColor(entry.kind))
            }
            .width(90)
            TableColumn("Latency") { entry in
                Text(entry.latencyMs > 0 ? "\(Int(entry.latencyMs))ms" : "—")
                    .font(.system(.caption, design: .monospaced))
            }
            .width(70)
            TableColumn("Prompt tail") { entry in
                Text(entry.promptTail)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            TableColumn("Ghost") { entry in
                Text(entry.ghostText)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 240)
    }

    private func outcomeLabel(_ kind: SuggestionEventKind) -> String {
        switch kind {
        case .shown:        "Shown"
        case .accepted:      "Accepted"
        case .rejected:      "Rejected"
        case .dismissed:     "Dismissed"
        case .typedThrough:  "Typed through"
        }
    }

    private func outcomeColor(_ kind: SuggestionEventKind) -> Color {
        switch kind {
        case .shown:        .secondary
        case .accepted:      .green
        case .rejected:      .red
        case .dismissed:     .orange
        case .typedThrough:  .blue
        }
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

    private func refresh() async {
        entries = deps.debugBuffer.recent
        let events = await deps.eventStore.allEvents()
        acceptanceRate = SuggestionMetrics.acceptanceRate(events: events)
        let (p50, p95) = SuggestionMetrics.latencyPercentiles(events: events)
        latencyP50 = p50
        latencyP95 = p95
    }
}
