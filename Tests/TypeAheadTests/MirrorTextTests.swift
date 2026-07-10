import Testing
@testable import TypeAhead

@Suite struct MirrorTextTests {
    @Test func multiLineInputTakesLastLineOnly() {
        let line = MirrorText.compose(textBeforeCursor: "line one\nline two\nI want to", ghost: " check")
        #expect(line.typedTail == "I want to")
        #expect(line.ghost == " check")
    }

    @Test func shortInputPassesThrough() {
        let line = MirrorText.compose(textBeforeCursor: "hello world", ghost: " foo")
        #expect(line.typedTail == "hello world")
        #expect(line.ghost == " foo")
    }

    @Test func emptyTextBeforeCursorGivesEmptyTypedTail() {
        let line = MirrorText.compose(textBeforeCursor: "", ghost: " hi")
        #expect(line.typedTail == "")
        #expect(line.ghost == " hi")
    }

    @Test func longLineTrimsAtWordBoundaryWithEllipsis() {
        // "the quick brown fox jumps over lazy dog" is 39 chars. The last 15 characters are
        // "s over lazy dog" (cutting mid-word through "jumps"), so the algorithm should trim
        // forward to the next word boundary and prepend an ellipsis.
        let line = MirrorText.compose(
            textBeforeCursor: "the quick brown fox jumps over lazy dog",
            ghost: " today",
            maxTypedChars: 15
        )
        #expect(line.typedTail == "…over lazy dog")
        #expect(line.ghost == " today")
    }

    @Test func longLineWithNoWordBoundaryInTailFallsBackToRawCut() {
        // A single very long "word" (no spaces) longer than maxTypedChars — no boundary to cut
        // at, so the raw suffix is kept with the ellipsis prefix.
        let line = MirrorText.compose(
            textBeforeCursor: "supercalifragilisticexpialidocious",
            ghost: "!",
            maxTypedChars: 10
        )
        #expect(line.typedTail == "…alidocious")
        #expect(line.typedTail.hasPrefix("…"))
        #expect(line.ghost == "!")
    }

    @Test func lineExactlyAtMaxCharsIsNotTrimmed() {
        let line = MirrorText.compose(textBeforeCursor: "exactly ten", ghost: "", maxTypedChars: 11)
        #expect(line.typedTail == "exactly ten")
    }

    @Test func multiLineLastLineStillTrimsWhenTooLong() {
        let line = MirrorText.compose(
            textBeforeCursor: "short first line\nthe quick brown fox jumps over lazy dog",
            ghost: " today",
            maxTypedChars: 15
        )
        #expect(line.typedTail == "…over lazy dog")
    }
}
