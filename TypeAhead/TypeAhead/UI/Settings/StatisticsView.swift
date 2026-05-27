import SwiftUI

struct StatisticsView: View {
    @State private var keystrokesSaved = 0
    private let store = AppDependencies.shared.historyStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    statCard(title: "Keystrokes Saved", value: "\(keystrokesSaved)")
                }
            }
            .padding()
        }
        .navigationTitle("Statistics")
        .task {
            let phrases = await store.recentAcceptedPhrases(limit: 1000)
            keystrokesSaved = StatisticsCalculator.keystrokesSaved(from: phrases)
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
}
