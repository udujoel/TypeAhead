import AppKit

enum OverlayPositioner {

    /// Positions the panel inline — immediately to the right of the cursor at the same baseline.
    /// `cursorRect` uses screen coordinates (bottom-left origin, Y increases upward).
    static func inlineOrigin(cursorRect: NSRect, panelSize: NSSize) -> NSPoint {
        let x = cursorRect.maxX
        // Anchor the panel bottom at the caret glyph's bottom. The panel is sized to the
        // font's natural line height, so the ghost's baseline lines up with the input's.
        let y = cursorRect.minY

        // Pick the screen the cursor is on; fall back to main screen
        let screen = NSScreen.screens.first {
            NSPointInRect(cursorRect.origin, $0.frame)
        } ?? NSScreen.main

        guard let screen else { return NSPoint(x: x, y: y) }

        return clampedOrigin(x: x, y: y, panelSize: panelSize, visibleFrame: screen.visibleFrame)
    }

    /// True iff `rect`'s origin lies within the union of `screenFrames` and the rect is
    /// non-degenerate (finite, positive height). Negative coordinates are LEGAL for
    /// monitors arranged left of / below the primary, so we test against actual screen
    /// frames rather than `> 0`. Used to reject the off-screen caret bounds that Electron
    /// apps (Teams, Slack, Claude desktop) report for their Chromium text fields, e.g.
    /// `cursor=(-2427.23, -139.98)` — outside every screen.
    static func isOnScreen(_ rect: NSRect, screenFrames: [NSRect]) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.height > 0 else { return false }
        return screenFrames.contains { NSPointInRect(rect.origin, $0) }
    }

    /// Clamps a desired panel origin so the panel stays inside `visibleFrame`. Clamps X on
    /// both sides (a far-left/negative anchor no longer pushes the ghost off-screen) and
    /// keeps the bottom edge above the screen's bottom.
    static func clampedOrigin(x: CGFloat, y: CGFloat, panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let clampedX = min(max(x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
        let clampedY = max(y, visibleFrame.minY)
        return NSPoint(x: clampedX, y: clampedY)
    }

    /// Origin for a bar anchored to the focused text element's own frame — just ABOVE the
    /// compose box, left-aligned with a small inset, so the ghost is clearly associated with
    /// the input without covering the text being typed. Used for Electron apps whose caret
    /// bounds lie but whose element frame is still valid (e.g. Claude desktop); one rung more
    /// precise than the window-corner `pinnedOrigin`.
    static func elementAnchoredOrigin(elementFrame: NSRect, panelSize: NSSize) -> NSPoint {
        let x = elementFrame.minX + 8
        let y = elementFrame.maxY + 4
        let screen = NSScreen.screens.first {
            NSPointInRect(elementFrame.origin, $0.frame)
        } ?? NSScreen.main
        guard let screen else { return NSPoint(x: x, y: y) }
        return clampedOrigin(x: x, y: y, panelSize: panelSize, visibleFrame: screen.visibleFrame)
    }

    /// Origin for a bar pinned just above the focused window's bottom edge (where chat/input
    /// fields live). Used as the last resort when neither Vision nor AX can locate the caret.
    /// X is placed at 25% from the window's left edge — past typical left sidebars in
    /// Electron apps (Teams, Slack, Claude Desktop) so the bar lands in the compose area.
    /// Clamped to stay within the window frame.
    static func pinnedOrigin(windowFrame: NSRect, panelSize: NSSize) -> NSPoint {
        let bottomGap: CGFloat = 8
        let x = windowFrame.minX + windowFrame.width * 0.25
        let y = windowFrame.minY + bottomGap
        // Clamp inside the window frame so a narrow window can't push the bar off the left.
        let clampedX = min(max(x, windowFrame.minX), max(windowFrame.minX, windowFrame.maxX - panelSize.width))
        return NSPoint(x: clampedX, y: y)
    }
}
