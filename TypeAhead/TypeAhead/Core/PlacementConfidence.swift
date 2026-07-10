import AppKit

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
    /// The focused text element's own AX frame (compose box rect) — no caret-level signal, but
    /// the ghost can be anchored to the input field itself. Electron apps whose caret bounds lie
    /// (Claude desktop, Slack) usually still report a valid element frame, so this beats the
    /// window-corner pinned bar whenever it's available.
    case elementFrame
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
    /// Paint the ghost as a Cotypist-style MIRROR: a two-tone bar that re-renders the tail of the
    /// typed text (normal color) followed by the ghost (grey), reading as one continuous line.
    /// Alignment to the real caret doesn't matter here — the mirror carries its own copy of the
    /// text — so this covers both the `elementFrame` and `approximate` tiers. Replaces the old
    /// bare `.pinnedBar` look; nothing uses that anymore.
    case mirror
    /// Don't show the ghost at all — the placement guess is untrustworthy enough that painting it
    /// anywhere would read as "buggy app."
    case suppress
}

/// Pure mapping from placement confidence to presentation policy. Doesn't touch AX/Vision so it's
/// trivially unit-testable.
enum PlacementPolicy {
    static func presentation(for tier: PlacementTier) -> PlacementPresentation {
        switch tier {
        case .exactAX, .visionFresh, .visionStale:
            return .inline
        case .elementFrame, .approximate:
            // Both are honest approximations (anchored to the input field / window input area) —
            // shown as a mirror, never claiming caret precision.
            return .mirror
        case .unknown:
            return .suppress
        }
    }
}

/// A caret-location guess plus how confident `AccessibilityManager.cursorScreenRect()` is in it.
/// `rect` is always in Cocoa screen coordinates, same as the pre-WS5 bare `NSRect` return.
struct CaretPlacement: Equatable {
    let rect: NSRect
    let tier: PlacementTier

    /// Where this placement should be presented, per `PlacementPolicy`.
    var presentation: PlacementPresentation { PlacementPolicy.presentation(for: tier) }
}
