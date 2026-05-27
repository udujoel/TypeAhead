import Testing
@testable import TypeAhead

@Suite struct StatisticsCalculatorTests {
    @Test func keystrokesSavedIsZeroForEmptyHistory() {
        #expect(StatisticsCalculator.keystrokesSaved(from: []) == 0)
    }

    @Test func keystrokesSavedSumsCharacterCounts() {
        let phrases = ["hello", "world"]
        #expect(StatisticsCalculator.keystrokesSaved(from: phrases) == 10)
    }

    @Test func acceptanceRateReturnsZeroForNoShown() {
        #expect(StatisticsCalculator.acceptanceRate(shown: 0, accepted: 0) == 0)
    }

    @Test func acceptanceRateCalculatesCorrectly() {
        #expect(StatisticsCalculator.acceptanceRate(shown: 100, accepted: 65) == 0.65)
    }
}
