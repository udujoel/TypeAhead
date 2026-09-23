import Testing
@testable import TypeAhead

/// Word alternatives (Cotypist Labs): ⌥↓ on a visible ghost lists up to three other choices for
/// its first word; pressing 1–3 inserts one.
@Suite struct WordAlternativesTests {

    // MARK: - Ranking candidates

    @Test func dedupesCaseInsensitivelyAndExcludesTheCurrentWord() {
        let list = WordAlternatives.rank(["Report", "report", "summary", "memo", "notes"], excluding: "report", limit: 3)
        #expect(list == ["summary", "memo", "notes"])
    }

    @Test func stripsWhitespaceAndTrailingPunctuationAndDropsEmpties() {
        let list = WordAlternatives.rank([" soon.", "", "  ", "later,", "today!"], excluding: nil, limit: 3)
        #expect(list == ["soon", "later", "today"])
    }

    @Test func keepsOnlyTheFirstWordOfMultiWordSamples() {
        #expect(WordAlternatives.rank(["next week", "tomorrow morning"], excluding: nil, limit: 3) == ["next", "tomorrow"])
    }

    @Test func excludedWordIsMatchedWithoutItsPunctuation() {
        // Ghost " meeting." must not list "meeting" as its own alternative.
        #expect(WordAlternatives.rank([" meeting,", "call"], excluding: "meeting.", limit: 3) == ["call"])
    }

    @Test func respectsLimit() {
        #expect(WordAlternatives.rank(["a1", "b1", "c1", "d1"], excluding: nil, limit: 2) == ["a1", "b1"])
    }

    // MARK: - What a choice inserts

    @Test func newWordChoiceKeepsTheGhostsLeadingSpace() {
        #expect(WordAlternatives.insertion(for: "memo", ghost: " report is ready", partialWord: "", trailingSpace: true) == " memo ")
        #expect(WordAlternatives.insertion(for: "memo", ghost: "report", partialWord: "", trailingSpace: false) == "memo")
    }

    @Test func midWordChoiceInsertsOnlyTheMissingLetters() {
        // Typed "wor", ghost "ld"; choosing "work" inserts "k".
        #expect(WordAlternatives.insertion(for: "work", ghost: "ld peace", partialWord: "wor", trailingSpace: true) == "k ")
    }

    @Test func midWordChoiceThatDoesNotExtendThePartialIsRejected() {
        #expect(WordAlternatives.insertion(for: "play", ghost: "ld", partialWord: "wor", trailingSpace: true) == nil)
    }

    @Test func firstWordOfGhost() {
        #expect(WordAlternatives.firstWord(ofGhost: " report is ready") == "report")
        #expect(WordAlternatives.firstWord(ofGhost: "ld peace") == "ld")
        #expect(WordAlternatives.firstWord(ofGhost: "   ") == nil)
    }
}
