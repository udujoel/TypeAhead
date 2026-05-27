import Testing
@testable import TypeAhead

@Suite struct AccessibilityManagerTests {
    @Test func extractsTextBeforeAndAfterCursor() {
        let full = "Hello world, how are you"
        let cursorPos = 11
        let (before, after) = AccessibilityManager.split(text: full, at: cursorPos)
        #expect(before == "Hello world")
        #expect(after == ", how are you")
    }

    @Test func handlesEmptyString() {
        let (before, after) = AccessibilityManager.split(text: "", at: 0)
        #expect(before == "")
        #expect(after == "")
    }

    @Test func handlesCursorAtEnd() {
        let text = "Hello"
        let (before, after) = AccessibilityManager.split(text: text, at: text.count)
        #expect(before == "Hello")
        #expect(after == "")
    }

    @Test func clampsCursorBeyondLength() {
        let text = "Hi"
        let (before, after) = AccessibilityManager.split(text: text, at: 100)
        #expect(before == "Hi")
        #expect(after == "")
    }
}
