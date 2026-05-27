import Testing
@testable import TypeAhead
import AppKit

@Suite struct OverlayPositionerTests {
    @Test func originIsBelowCursorRect() {
        let cursorRect = NSRect(x: 200, y: 500, width: 2, height: 16)
        let panelSize = NSSize(width: 300, height: 32)
        let origin = OverlayPositioner.panelOrigin(cursorRect: cursorRect, panelSize: panelSize)
        #expect(origin.y + panelSize.height < cursorRect.minY)
    }

    @Test func originIsLeftAligned() {
        let cursorRect = NSRect(x: 300, y: 400, width: 2, height: 16)
        let panelSize = NSSize(width: 200, height: 32)
        let origin = OverlayPositioner.panelOrigin(cursorRect: cursorRect, panelSize: panelSize)
        #expect(origin.x == 300)
    }
}
