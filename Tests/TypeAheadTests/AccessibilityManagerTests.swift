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

    // MARK: - Silent-no-op detection (Electron AX write that returns .success but does nothing)

    @Test func pureInsertionThatDidNotGrowIsNoOp() {
        // Empty selection (caret), field length unchanged after a .success write → Electron no-op.
        #expect(AccessibilityManager.isSilentNoOp(selectionLength: 0, lengthBefore: 10, lengthAfter: 10))
    }

    @Test func pureInsertionThatGrewIsNotNoOp() {
        #expect(!AccessibilityManager.isSilentNoOp(selectionLength: 0, lengthBefore: 10, lengthAfter: 15))
    }

    @Test func replacementThatShrankFieldIsNotNoOp() {
        // The :wave → 👋 case: 5 chars selected, replaced by 1 → field shrinks by 4. A
        // successful write, NOT a no-op. Length-based check must not fire here (would double-insert).
        #expect(!AccessibilityManager.isSilentNoOp(selectionLength: 5, lengthBefore: 10, lengthAfter: 6))
    }

    @Test func replacementOfEqualLengthIsNotNoOp() {
        // "colour" → "color " : selection replaced by same-length text → field unchanged but
        // the write DID happen. With a selection present we cannot verify by length, so trust it.
        #expect(!AccessibilityManager.isSilentNoOp(selectionLength: 6, lengthBefore: 10, lengthAfter: 10))
    }

    @Test func unreadableBeforeLengthIsNotNoOp() {
        #expect(!AccessibilityManager.isSilentNoOp(selectionLength: 0, lengthBefore: nil, lengthAfter: 10))
    }

    @Test func unreadableAfterLengthIsNotNoOp() {
        #expect(!AccessibilityManager.isSilentNoOp(selectionLength: 0, lengthBefore: 10, lengthAfter: nil))
    }
}
