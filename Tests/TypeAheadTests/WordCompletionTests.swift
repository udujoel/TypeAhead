import Testing
@testable import TypeAhead

/// Tests for mid-word detection (ContextBuilder.currentWord) which drives both the
/// word-completion path (ghost completes the partial word, Tab replaces it) and the
/// leading-space logic (no space when completing a word already in progress).
@Suite struct WordCompletionTests {

    // MARK: - currentWord detection

    @Test func nilWhenCursorAtWordBoundary() {
        let ctx = TextContext(textBeforeCursor: "hello ", textAfterCursor: "", appName: "", windowTitle: "")
        #expect(ContextBuilder.currentWord(context: ctx) == nil)
    }

    @Test func nilWhenEmpty() {
        let ctx = TextContext(textBeforeCursor: "", textAfterCursor: "", appName: "", windowTitle: "")
        #expect(ContextBuilder.currentWord(context: ctx) == nil)
    }

    @Test func returnsPartialWordAtEndOfPrefix() {
        let ctx = TextContext(textBeforeCursor: "I am typ", textAfterCursor: "", appName: "", windowTitle: "")
        #expect(ContextBuilder.currentWord(context: ctx) == "typ")
    }

    @Test func returnsFullWordIfNoPriorSpace() {
        let ctx = TextContext(textBeforeCursor: "hello", textAfterCursor: "", appName: "", windowTitle: "")
        #expect(ContextBuilder.currentWord(context: ctx) == "hello")
    }

    @Test func returnsLastWordWhenMultipleWords() {
        let ctx = TextContext(textBeforeCursor: "The quick brow", textAfterCursor: "", appName: "", windowTitle: "")
        #expect(ContextBuilder.currentWord(context: ctx) == "brow")
    }

    @Test func nilWhenCursorAfterNewline() {
        let ctx = TextContext(textBeforeCursor: "first line\n", textAfterCursor: "", appName: "", windowTitle: "")
        #expect(ContextBuilder.currentWord(context: ctx) == nil)
    }

    @Test func returnsWordAfterNewline() {
        let ctx = TextContext(textBeforeCursor: "first line\nseco", textAfterCursor: "", appName: "", windowTitle: "")
        #expect(ContextBuilder.currentWord(context: ctx) == "seco")
    }

    // MARK: - GhostText leading-space interaction

    /// When completing a mid-word (ghost has no leading space), Tab should replace the
    /// partial word — not append. Verify the ghost itself has no leading space.
    @Test func ghostHasNoLeadingSpaceForMidWordRaw() {
        // Model output that directly continues the word (no whitespace start)
        let result = GhostText.build(typed: "I am typ", raw: "typing", isFillInMiddle: true, maxWords: 4)
        #expect(!result.hasPrefix(" "))
    }

    /// When the cursor is at a word boundary, the ghost should carry a leading space
    /// before the next word.
    @Test func ghostHasLeadingSpaceForNewWord() {
        // Raw starts with space → new word
        let result = GhostText.build(typed: "I am", raw: " typing fast", isFillInMiddle: true, maxWords: 4)
        #expect(result.hasPrefix(" "))
    }
}
