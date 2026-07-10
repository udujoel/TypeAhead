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

    @Test func approximatePresentsPinnedBar() {
        #expect(PlacementPolicy.presentation(for: .approximate) == .pinnedBar)
    }

    @Test func elementFramePresentsPinnedBar() {
        // The compose box's own frame is an honest approximation — anchored to the input,
        // but never claiming caret precision.
        #expect(PlacementPolicy.presentation(for: .elementFrame) == .pinnedBar)
    }

    @Test func unknownPresentsSuppress() {
        #expect(PlacementPolicy.presentation(for: .unknown) == .suppress)
    }

    // MARK: - Inference early-out (CompletionCoordinator.shouldRunInference)

    @Test func inferenceRunsForInlinePresentation() {
        #expect(CompletionCoordinator.shouldRunInference(presentation: .inline))
    }

    @Test func inferenceRunsForPinnedBarPresentation() {
        #expect(CompletionCoordinator.shouldRunInference(presentation: .pinnedBar))
    }

    @Test func inferenceSkippedForSuppressedPresentation() {
        // A suppressed placement can never paint, so the ML path must bail before starting an
        // MLX generation (wasted battery/latency otherwise).
        #expect(!CompletionCoordinator.shouldRunInference(presentation: .suppress))
    }

    // MARK: - Element-anchored positioning (OverlayPositioner.elementAnchoredOrigin)

    @Test func elementAnchoredOriginSitsAboveTheComposeBox() {
        // A frame well inside any plausible screen so clamping never kicks in — the bar goes
        // 8pt in from the element's left edge and 4pt above its top, never covering the text.
        let element = NSRect(x: 100, y: 100, width: 400, height: 50)
        let origin = OverlayPositioner.elementAnchoredOrigin(
            elementFrame: element, panelSize: NSSize(width: 120, height: 20))
        #expect(origin.x == element.minX + 8)
        #expect(origin.y == element.maxY + 4)
    }

    @Test func everyTierHasAnExplicitMapping() {
        // Guards against a new PlacementTier case silently falling through to a default —
        // there is no default branch in PlacementPolicy.presentation, so this is really just
        // documentation, but it pins the full enumeration down for future readers/reviewers.
        let all: [PlacementTier] = [.exactAX, .visionFresh, .visionStale, .elementFrame, .approximate, .unknown]
        let presentations = all.map(PlacementPolicy.presentation)
        #expect(presentations == [.inline, .inline, .inline, .pinnedBar, .pinnedBar, .suppress])
    }
}
