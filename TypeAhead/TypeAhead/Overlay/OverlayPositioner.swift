import AppKit

enum OverlayPositioner {
    static func panelOrigin(cursorRect: NSRect, panelSize: NSSize) -> NSPoint {
        let x = cursorRect.minX
        let y = cursorRect.minY - panelSize.height - 8
        guard let screen = NSScreen.main else { return NSPoint(x: x, y: y) }
        let clamped = NSPoint(
            x: min(max(x, screen.visibleFrame.minX), screen.visibleFrame.maxX - panelSize.width),
            y: max(y, screen.visibleFrame.minY)
        )
        return clamped
    }
}
