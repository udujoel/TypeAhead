import Foundation

enum StatisticsCalculator {
    static func keystrokesSaved(from acceptedPhrases: [String]) -> Int {
        acceptedPhrases.reduce(0) { $0 + $1.count }
    }

    static func acceptanceRate(shown: Int, accepted: Int) -> Double {
        guard shown > 0 else { return 0 }
        return Double(accepted) / Double(shown)
    }
}
