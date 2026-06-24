import Testing
@testable import TypeAhead
import AppKit

@Suite struct CaretGeometryTests {
    private let window = NSRect(x: 1000, y: 500, width: 800, height: 600)

    // MARK: - top-left (Quartz/SCKit) → Cocoa flip

    @Test func flipToCocoaInvertsYAroundMenuBarHeight() {
        // Primary screen 1920x1080 → menuBarHeight (its Cocoa maxY) = 1080.
        // A window whose top-left frame is (100, 50) size 800x600: its bottom edge in top-left
        // coords is y=650; in Cocoa bottom-left that's 1080-650 = 430.
        let cocoa = CaretGeometry.flipToCocoa(topLeftFrame: CGRect(x: 100, y: 50, width: 800, height: 600), menuBarHeight: 1080)
        #expect(cocoa.minX == 100)
        #expect(cocoa.minY == 430)
        #expect(cocoa.width == 800)
        #expect(cocoa.height == 600)
    }

    @Test func flipToCocoaIsSelfInverse() {
        // Flipping twice returns the original frame (the operation is its own inverse).
        let original = CGRect(x: 12, y: 34, width: 560, height: 780)
        let once = CaretGeometry.flipToCocoa(topLeftFrame: original, menuBarHeight: 1080)
        let twice = CaretGeometry.flipToCocoa(topLeftFrame: once, menuBarHeight: 1080)
        #expect(twice == original)
    }

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

    /// When the just-typed text matches equally well in two places — e.g. a sent chat message
    /// AND the compose box — anchor to the BOTTOM-most one. The text the user is actively typing
    /// lives in the compose box, which sits at the bottom of virtually every chat app. Without
    /// this, the ghost can attach to an old message higher up the window.
    @Test func bestMatchPrefersBottomMostOnEqualScore() {
        let obs = [
            // Sent message near the top (normalized bottom-left: high Y = high on screen).
            CaretGeometry.Observation(text: "see you tomorrow", box: NSRect(x: 0.1, y: 0.85, width: 0.4, height: 0.03)),
            // The same words echoed in the compose box near the bottom (low Y).
            CaretGeometry.Observation(text: "see you tomorrow", box: NSRect(x: 0.1, y: 0.05, width: 0.4, height: 0.03)),
        ]
        let anchor = CaretGeometry.bestMatch(trailingText: "see you tomorrow", observations: obs, in: window)
        #expect(anchor != nil)
        // Bottom box minY = 0.05 → screen y = 500 + 0.05*600 = 530, not the top box's 1010.
        let expectedBottomY = window.minY + 0.05 * window.height
        #expect(abs(anchor!.minY - expectedBottomY) < 1.0, "should anchor to the bottom-most (compose-box) match")
    }

    /// Long trailing text whose OCR snapshot only captured a short suffix should still match.
    /// Threshold is capped at 8 chars so "check re" (8 chars) found within a 20-char needle
    /// still satisfies the confidence bar.
    @Test func bestMatchLongNeedleShortSuffixStillMatches() {
        // OCR captured the input line before later chars were typed; observation text is "check re".
        let obs = [
            CaretGeometry.Observation(text: "check re", box: NSRect(x: 0.1, y: 0.1, width: 0.3, height: 0.03)),
        ]
        // Needle is the full typed trailing text — longer than what OCR saw.
        let anchor = CaretGeometry.bestMatch(trailingText: "check review from the PR", observations: obs, in: window)
        #expect(anchor != nil, "short OCR suffix should still anchor when needle is long")
    }
}
