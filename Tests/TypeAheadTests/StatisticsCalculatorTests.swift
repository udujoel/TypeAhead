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

    // MARK: - percentiles

    @Test func percentilesReturnsZeroForEmptyInput() {
        let (p50, p95) = StatisticsCalculator.percentiles([])
        #expect(p50 == 0)
        #expect(p95 == 0)
    }

    @Test func percentilesReturnsSameValueForSingleElement() {
        let (p50, p95) = StatisticsCalculator.percentiles([42])
        #expect(p50 == 42)
        #expect(p95 == 42)
    }

    @Test func percentilesAreOrderIndependent() {
        let values: [Double] = [50, 10, 90, 20, 80, 30, 70, 40, 60, 100]
        let (p50, p95) = StatisticsCalculator.percentiles(values)
        let (p50Sorted, p95Sorted) = StatisticsCalculator.percentiles(values.sorted())
        #expect(p50 == p50Sorted)
        #expect(p95 == p95Sorted)
    }

    @Test func p95IsAlwaysGreaterOrEqualP50() {
        let values: [Double] = (1...100).map(Double.init)
        let (p50, p95) = StatisticsCalculator.percentiles(values)
        #expect(p95 >= p50)
    }

    @Test func percentilesOnUniformValuesReturnsThatValue() {
        let (p50, p95) = StatisticsCalculator.percentiles([Double](repeating: 100, count: 20))
        #expect(p50 == 100)
        #expect(p95 == 100)
    }
}
