import AppKit

enum OverlayPositioner {

    /// Positions the panel inline — immediately to the right of the cursor at the same baseline.
    /// `cursorRect` uses screen coordinates (bottom-left origin, Y increases upward).
    static func inlineOrigin(cursorRect: NSRect, panelSize: NSSize) -> NSPoint {
        let x = cursorRect.maxX
        // The AX caret rect (kAXBoundsForRange) sits ~one glyph-height above where the text
        // actually renders in TextEdit-style views, so the overlay appeared a line too high.
        // Drop it by the glyph height so the ghost lands on the text baseline.
        let y = cursorRect.minY - cursorRect.height

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
