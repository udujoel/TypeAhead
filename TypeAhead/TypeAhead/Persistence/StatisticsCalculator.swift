import Foundation

enum StatisticsCalculator {
    static func keystrokesSaved(from acceptedPhrases: [String]) -> Int {
        acceptedPhrases.reduce(0) { $0 + $1.count }
    }

    static func acceptanceRate(shown: Int, accepted: Int) -> Double {
        guard shown > 0 else { return 0 }
        return Double(accepted) / Double(shown)
    }

    /// Nearest-rank P50/P95 over `values`. Order-independent (sorts internally). Returns
    /// (0, 0) for an empty input rather than trapping — callers with no data yet (e.g. a
    /// fresh install) should see zeros, not a crash.
    static func percentiles(_ values: [Double]) -> (p50: Double, p95: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double {
            let index = Int((p * Double(sorted.count - 1)).rounded())
            return sorted[min(max(index, 0), sorted.count - 1)]
        }
        return (rank(0.5), rank(0.95))
    }
}
