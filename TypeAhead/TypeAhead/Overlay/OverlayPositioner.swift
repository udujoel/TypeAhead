import AppKit

enum OverlayPositioner {

    /// Positions the panel inline — immediately to the right of the cursor at the same baseline.
    /// `cursorRect` uses screen coordinates (bottom-left origin, Y increases upward).
    static func inlineOrigin(cursorRect: NSRect, panelSize: NSSize) -> NSPoint {
        let x = cursorRect.maxX
        // Empirically calibrated from logged panel-vs-caret frames: with no shift the ghost
        // sits ~half a glyph-height high (NSTextField draws text above its center); shifting a
        // full glyph height dropped it a line too low. Half the glyph height lands it on the line.
        let y = cursorRect.minY - cursorRect.height / 2

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
