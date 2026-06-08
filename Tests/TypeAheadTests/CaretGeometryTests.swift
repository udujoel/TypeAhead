import Testing
@testable import TypeAhead
import AppKit

@Suite struct CaretGeometryTests {
    private let window = NSRect(x: 1000, y: 500, width: 800, height: 600)

    // MARK: - normalized → screen

    @Test func normalizedCenterMapsToWindowCenter() {
        let norm = NSRect(x: 0.5, y: 0.5, width: 0, height: 0)
        let r = CaretGeometry.screenRect(fromNormalized: norm, in: window)
        #expect(abs(r.midX - window.midX) < 0.01)
        #expect(abs(r.midY - window.midY) < 0.01)
    }

    @Test func normalizedBottomLeftMapsToWindowOrigin() {
        let norm = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let r = CaretGeometry.screenRect(fromNormalized: norm, in: window)
        #expect(abs(r.minX - window.minX) < 0.01)
        #expect(abs(r.minY - window.minY) < 0.01)
    }

    // MARK: - bestMatch (anchor at right edge of the matched text)

    @Test func bestMatchAnchorsToTrailingText() {
        // Two observations; the trailing typed text "input point" matches the second.
        let obs = [
            CaretGeometry.Observation(text: "The suggestion is", box: NSRect(x: 0.1, y: 0.8, width: 0.3, height: 0.03)),
            CaretGeometry.Observation(text: "off from the input point", box: NSRect(x: 0.1, y: 0.5, width: 0.4, height: 0.03)),
        ]
        let anchor = CaretGeometry.bestMatch(trailingText: "input point", observations: obs, in: window)
        #expect(anchor != nil)
        // Anchored to the RIGHT edge of the matched box.
        let expectedX = window.minX + 0.5 * window.width // box.maxX = 0.1+0.4
        #expect(abs(anchor!.minX - expectedX) < 0.5)
    }

    @Test func bestMatchReturnsNilBelowConfidence() {
        let obs = [
            CaretGeometry.Observation(text: "completely unrelated text", box: NSRect(x: 0.1, y: 0.5, width: 0.4, height: 0.03)),
        ]
        #expect(CaretGeometry.bestMatch(trailingText: "input point", observations: obs, in: window) == nil)
    }

    @Test func bestMatchReturnsNilForEmptyTrailing() {
        let obs = [CaretGeometry.Observation(text: "anything", box: NSRect(x: 0, y: 0, width: 0.1, height: 0.03))]
        #expect(CaretGeometry.bestMatch(trailingText: "", observations: obs, in: window) == nil)
    }
}
