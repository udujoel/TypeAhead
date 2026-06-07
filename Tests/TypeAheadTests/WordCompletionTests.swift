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

    // MARK: - Insert-suffix behaviour

    /// Ghost in fill-in-middle mode is already the suffix after the cursor.
    /// Inserting the suffix directly appends to the partial word already in the field:
    /// field="wor" + insert("king ") = "working ". No replacement needed.
    @Test func ghostSuffixInsertedAfterPartialGivesFullWord() {
        // Simulate what GhostText.build returns for typed="wor", raw="king"
        let ghost = GhostText.build(typed: "wor", raw: "king", isFillInMiddle: true, maxWords: 4)
        // Ghost is the suffix — no leading space for mid-word continuation.
        #expect(ghost == "king")
        #expect(!ghost.hasPrefix(" "))
        // Tab inserts ghost + " " after the partial; the field already has "wor".
        // "wor" (in field) + "king " (inserted) = "working ".
        let textInField = "wor"
        let afterInsert = textInField + ghost + " "
        #expect(afterInsert == "working ")
    }

    @Test func newWordGhostHasLeadingSpaceAndInsertsCorrectly() {
        // After a complete word (cursor at space boundary), ghost carries a leading space.
        let ghost = GhostText.build(typed: "I am", raw: " worried", isFillInMiddle: true, maxWords: 4)
        #expect(ghost.hasPrefix(" "))
        // Tab inserts the ghost (including its leading space) + trailing space.
        let injection = ghost + " "
        #expect(injection == " worried ")
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
