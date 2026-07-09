import Foundation

/// How confident `AccessibilityManager.cursorScreenRect()` is in the rect it just returned.
/// Every rung of the fallback ladder (reliable-AX caret → fresh Vision OCR anchor → stale Vision
/// anchor → AX rect anyway → pinned bar → mouse position) tags its result with one of these so
/// callers can degrade honestly instead of painting the ghost at a wrong-looking spot with no
/// indication anything's off (see WS5 in the product overhaul design doc).
enum PlacementTier: String, Equatable, Sendable {
    /// A precise AX caret-glyph rect — either the reliable-app fast path, or the unreliable-app
    /// ladder's "AX rect anyway" rung when Vision has nothing. Same underlying mechanism
    /// (`onScreenAXCaretRect()`), same confidence.
    case exactAX
    /// A fresh (within-TTL) Vision OCR anchor for an unreliable-caret-bounds app.
    case visionFresh
    /// A Vision OCR anchor whose TTL expired but is still from the current window — pixel-accurate
    /// from a real scan, just possibly stale if the text has since scrolled/changed.
    case visionStale
    /// The window-corner pinned bar — no caret-level signal at all, just "somewhere in this
    /// window's input area."
    case approximate
    /// Mouse position — not the caret at all. The ladder's last resort.
    case unknown
}

/// Where (and whether) to paint the ghost for a given `PlacementTier`.
enum PlacementPresentation: Equatable, Sendable {
    /// Paint the ghost inline at the returned rect — current caret-anchored behavior.
    case inline
    /// Paint the ghost at the returned rect using the existing pinned-bar look, but never claim
    /// it's sitting at the caret.
    case pinnedBar
    /// Don't show the ghost at all — the placement guess is untrustworthy enough that painting it
    /// anywhere would read as "buggy app."
    case suppress
}

/// Pure mapping from placement confidence to presentation policy. No AX/AppKit dependency so it's
/// trivially unit-testable.
enum PlacementPolicy {
    static func presentation(for tier: PlacementTier) -> PlacementPresentation {
        switch tier {
        case .exactAX, .visionFresh, .visionStale:
            return .inline
        case .approximate:
            return .pinnedBar
        case .unknown:
            return .suppress
        }
    }
}
