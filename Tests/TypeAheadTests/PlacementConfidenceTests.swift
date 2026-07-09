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

    @Test func unknownPresentsSuppress() {
        #expect(PlacementPolicy.presentation(for: .unknown) == .suppress)
    }

    @Test func everyTierHasAnExplicitMapping() {
        // Guards against a new PlacementTier case silently falling through to a default —
        // there is no default branch in PlacementPolicy.presentation, so this is really just
        // documentation, but it pins the full enumeration down for future readers/reviewers.
        let all: [PlacementTier] = [.exactAX, .visionFresh, .visionStale, .approximate, .unknown]
        let presentations = all.map(PlacementPolicy.presentation)
        #expect(presentations == [.inline, .inline, .inline, .pinnedBar, .suppress])
    }
}
