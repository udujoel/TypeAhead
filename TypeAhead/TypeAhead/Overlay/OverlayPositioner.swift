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

        return NSPoint(
            x: min(x, screen.visibleFrame.maxX - panelSize.width),
            y: max(y, screen.visibleFrame.minY)
        )
    }
}
