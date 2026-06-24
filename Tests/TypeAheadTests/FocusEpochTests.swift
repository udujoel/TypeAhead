import Testing
@testable import TypeAhead

/// `FocusEpoch` tracks "focus epochs": each time the user moves to a different field/app the
/// epoch bumps. A suggestion generated in epoch N must not be accepted in a later epoch (it would
/// land in the wrong field). These tests pin that pure logic; the focus-change *detection*
/// (NSWorkspace / CFEqual) lives in the app layer and is verified by the build + manual test.
@MainActor
@Suite struct FocusEpochTests {

    @Test func startsAtZero() {
        let epoch = FocusEpoch()
        #expect(epoch.epoch == 0)
    }

    @Test func focusChangeBumpsEpoch() {
        let epoch = FocusEpoch()
        epoch.focusChanged()
        #expect(epoch.epoch == 1)
        epoch.focusChanged()
        #expect(epoch.epoch == 2)
    }

    @Test func mayAcceptWhenSameEpoch() {
        let epoch = FocusEpoch()
        let stamped = epoch.epoch
        #expect(epoch.mayAccept(stampedEpoch: stamped) == true)
    }

    @Test func mayNotAcceptAfterFocusChanged() {
        let epoch = FocusEpoch()
        let stamped = epoch.epoch   // 0
        epoch.focusChanged()        // now 1 — focus moved since the suggestion was made
        #expect(epoch.mayAccept(stampedEpoch: stamped) == false)
    }

    @Test func mayAcceptAgainOnceStampMatchesNewEpoch() {
        let epoch = FocusEpoch()
        epoch.focusChanged()                 // epoch 1
        let stamped = epoch.epoch            // stamp the *current* epoch
        #expect(epoch.mayAccept(stampedEpoch: stamped) == true)
    }
}
