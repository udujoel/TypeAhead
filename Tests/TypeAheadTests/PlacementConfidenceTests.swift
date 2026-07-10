import AppKit
import Testing
@testable import TypeAhead

@Suite struct PlacementConfidenceTests {
    @Test func exactAXPresentsInline() {
        #expect(PlacementPolicy.presentation(for: .exactAX) == .inline)
    }

    @Test func visionFreshPresentsInline() {
        #expect(PlacementPolicy.presentation(for: .visionFresh) == .inline)
    }

    @Test func visionStalePresentsInline() {
        #expect(PlacementPolicy.presentation(for: .visionStale) == .inline)
    }

    @Test func approximatePresentsMirror() {
        #expect(PlacementPolicy.presentation(for: .approximate) == .mirror)
    }

    @Test func elementFramePresentsMirror() {
        // The compose box's own frame is an honest approximation — anchored to the input,
        // but never claiming caret precision. Rendered as a Cotypist-style mirror (WP-A).
        #expect(PlacementPolicy.presentation(for: .elementFrame) == .mirror)
    }

    @Test func unknownPresentsSuppress() {
        #expect(PlacementPolicy.presentation(for: .unknown) == .suppress)
    }

    // MARK: - Inference early-out (CompletionCoordinator.shouldRunInference)

    @Test func inferenceRunsForInlinePresentation() {
        #expect(CompletionCoordinator.shouldRunInference(presentation: .inline))
    }

    @Test func inferenceRunsForMirrorPresentation() {
        #expect(CompletionCoordinator.shouldRunInference(presentation: .mirror))
    }

    @Test func inferenceSkippedForSuppressedPresentation() {
        // A suppressed placement can never paint, so the ML path must bail before starting an
        // MLX generation (wasted battery/latency otherwise).
        #expect(!CompletionCoordinator.shouldRunInference(presentation: .suppress))
    }

    // MARK: - Mirror positioning (OverlayPositioner.mirrorOrigin — WP-A)

    @Test func mirrorOriginSitsBelowTheComposeBoxWhenThereIsRoom() {
        // A frame well inside any plausible screen so clamping never kicks in, and far enough
        // from the bottom that "below the field" always fits — the mirror goes 8pt in from the
        // element's left edge and just under its bottom (panelHeight + 2pt gap), Cotypist's
        // "second line" look.
        let element = NSRect(x: 100, y: 300, width: 400, height: 50)
        let panelSize = NSSize(width: 200, height: 20)
        let origin = OverlayPositioner.mirrorOrigin(elementFrame: element, panelSize: panelSize)
        #expect(origin.x == element.minX + 8)
        #expect(origin.y == element.minY - panelSize.height - 2)
    }

    @Test func mirrorOriginFlipsAboveWhenBelowWouldRunOffscreen() {
        // An element pinned near the very bottom of the screen (minY = 5): placing the mirror
        // below it would push the panel's bottom past y = 0, so it flips to just above the
        // field instead — the panel stays readable rather than clamped off the visible area.
        let element = NSRect(x: 100, y: 5, width: 400, height: 50)
        let panelSize = NSSize(width: 200, height: 20)
        let origin = OverlayPositioner.mirrorOrigin(elementFrame: element, panelSize: panelSize)
        #expect(origin.x == element.minX + 8)
        #expect(origin.y == element.maxY + 4)
    }

    @Test func everyTierHasAnExplicitMapping() {
        // Guards against a new PlacementTier case silently falling through to a default —
        // there is no default branch in PlacementPolicy.presentation, so this is really just
        // documentation, but it pins the full enumeration down for future readers/reviewers.
        let all: [PlacementTier] = [.exactAX, .visionFresh, .visionStale, .elementFrame, .approximate, .unknown]
        let presentations = all.map(PlacementPolicy.presentation)
        #expect(presentations == [.inline, .inline, .inline, .mirror, .mirror, .suppress])
    }
}
