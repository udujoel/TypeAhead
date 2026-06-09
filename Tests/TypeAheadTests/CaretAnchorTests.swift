import Testing
@testable import TypeAhead
import AppKit

/// Tests for the pure caret-anchoring geometry used to keep the ghost overlay
/// on the same line as the caret — and to reject the off-screen AX bounds that
/// Electron apps (Teams, Slack, Claude desktop) report for their Chromium fields.
@Suite struct CaretAnchorTests {

    // A primary screen at the origin and a secondary monitor to the LEFT (legal
    // negative coordinates) — mirrors a real two-monitor layout.
    private let primary = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondaryLeft = NSRect(x: -1920, y: 0, width: 1920, height: 1080)

    // MARK: - isOnScreen (rect validation)

    @Test func caretInsidePrimaryScreenIsOnScreen() {
        let caret = NSRect(x: 400, y: 500, width: 0, height: 18)
        #expect(OverlayPositioner.isOnScreen(caret, screenFrames: [primary]))
    }

    @Test func negativeCaretOnSecondaryMonitorIsOnScreen() {
        // Legal: a caret on a monitor positioned to the left has a negative X.
        let caret = NSRect(x: -800, y: 300, width: 0, height: 18)
        #expect(OverlayPositioner.isOnScreen(caret, screenFrames: [primary, secondaryLeft]))
    }

    @Test func farNegativeCaretOffAllScreensIsNotOnScreen() {
        // The Electron failure mode: cursor=(-2427.23, -139.98) — outside every screen.
        let caret = NSRect(x: -2427.23, y: -139.98, width: 0, height: 20)
        #expect(!OverlayPositioner.isOnScreen(caret, screenFrames: [primary, secondaryLeft]))
    }

    @Test func degenerateZeroHeightCaretIsNotOnScreen() {
        let caret = NSRect(x: 400, y: 500, width: 0, height: 0)
        #expect(!OverlayPositioner.isOnScreen(caret, screenFrames: [primary]))
    }

    @Test func nonFiniteCaretIsNotOnScreen() {
        let caret = NSRect(x: CGFloat.nan, y: 500, width: 0, height: 18)
        #expect(!OverlayPositioner.isOnScreen(caret, screenFrames: [primary]))
    }

    // MARK: - clampedOrigin (keep the panel inside the visible frame)

    private let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let panel = NSSize(width: 300, height: 24)

    @Test func originInsideFrameIsUnchanged() {
        let origin = OverlayPositioner.clampedOrigin(x: 500, y: 400, panelSize: panel, visibleFrame: visible)
        #expect(origin.x == 500)
        #expect(origin.y == 400)
    }

    @Test func originPastRightEdgeIsClampedLeft() {
        let origin = OverlayPositioner.clampedOrigin(x: 1900, y: 400, panelSize: panel, visibleFrame: visible)
        #expect(origin.x == visible.maxX - panel.width) // 1620
    }

    @Test func negativeOriginIsClampedToLeftEdge() {
        let origin = OverlayPositioner.clampedOrigin(x: -500, y: 400, panelSize: panel, visibleFrame: visible)
        #expect(origin.x == visible.minX) // 0
    }

    @Test func originBelowBottomIsClampedUp() {
        let origin = OverlayPositioner.clampedOrigin(x: 500, y: -50, panelSize: panel, visibleFrame: visible)
        #expect(origin.y == visible.minY) // 0
    }

    // MARK: - pinnedOrigin (bar above the window's input)

    @Test func pinnedOriginSitsNearWindowBottom() {
        let window = NSRect(x: 100, y: 200, width: 800, height: 600)
        let p = OverlayPositioner.pinnedOrigin(windowFrame: window, panelSize: NSSize(width: 300, height: 24))
        // Just above the window's bottom edge, inset from the left.
        #expect(p.y >= window.minY)
        #expect(p.y < window.minY + 60)
        #expect(p.x >= window.minX)
        #expect(p.x <= window.maxX - 300)
    }

    /// PINNED x should land at ~25% from the left edge — past typical sidebars in Electron
    /// apps (Teams, Slack, Claude Desktop) so the bar lands in the compose area, not the rail.
    @Test func pinnedOriginXIsInLeftQuarter() {
        let window = NSRect(x: 0, y: 0, width: 1080, height: 900)
        let p = OverlayPositioner.pinnedOrigin(windowFrame: window, panelSize: NSSize(width: 200, height: 24))
        let expected = window.minX + window.width * 0.25 // = 270
        #expect(abs(p.x - expected) < 1, "PINNED x should be 25% from window left (\(expected)), got \(p.x)")
    }

    @Test func pinnedOriginClampsWideWindowInset() {
        let window = NSRect(x: 0, y: 0, width: 200, height: 400) // narrower than panel
        let p = OverlayPositioner.pinnedOrigin(windowFrame: window, panelSize: NSSize(width: 300, height: 24))
        #expect(p.x == window.minX) // can't inset past the left edge
    }

    // MARK: - CaretLocator.staleAnchor

    @Test @MainActor func staleAnchorReturnsCachedAnchorForSameWindow() {
        let locator = CaretLocator()
        let window = NSRect(x: 0, y: 0, width: 1336, height: 900)
        let anchor = NSRect(x: 600, y: 400, width: 0, height: 18)
        // Simulate Vision having found an anchor (set via freshAnchor / internal cache).
        // We do this by calling the internal method directly via @testable access.
        // CaretLocator.refresh is async; test the pure accessor independently.
        locator.testInjectAnchor(anchor, window: window)
        let result = locator.staleAnchor(forWindow: window)
        #expect(result == anchor, "staleAnchor must return cached anchor for the same window regardless of TTL")
    }

    @Test @MainActor func staleAnchorRejectsAnchorFromDifferentWindow() {
        let locator = CaretLocator()
        let windowA = NSRect(x: 0, y: 0, width: 1336, height: 900)
        let windowB = NSRect(x: 100, y: 0, width: 1080, height: 800)
        let anchor = NSRect(x: 600, y: 400, width: 0, height: 18)
        locator.testInjectAnchor(anchor, window: windowA)
        // Querying with a different window should return nil — never use a stale anchor
        // from the wrong window (user alt-tabbed between apps).
        #expect(locator.staleAnchor(forWindow: windowB) == nil)
    }

    @Test @MainActor func staleAnchorReturnsNilWhenNoCacheExists() {
        let locator = CaretLocator()
        let window = NSRect(x: 0, y: 0, width: 1336, height: 900)
        #expect(locator.staleAnchor(forWindow: window) == nil)
    }
}
