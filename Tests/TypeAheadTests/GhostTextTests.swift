import Testing
@testable import TypeAhead

@Suite struct GhostTextTests {

    // MARK: - The Tab bug: model restates the whole sentence

    @Test func restatementYieldsNoSpuriousContinuation() {
        // The model echoed the user's whole sentence from the beginning instead of
        // continuing at the cursor. The cursor is already at the end, so there is
        // nothing to add — we must NOT return "And …" (the old bug inserted its
        // first word on Tab).
        let typed = "starts adding the first word of the whole prediction, not from the position im at"
        let raw = "And pressing tab starts adding the first word of the whole prediction, not from the position im at"
        #expect(GhostText.alignedContinuation(typed: typed, output: raw) == "")
    }

    @Test func restatementWithNewTailKeepsOnlyTheTail() {
        // Output doesn't start with what was typed (model prepended "And thanks"),
        // but the typed tail appears inside it — keep only what follows.
        let typed = "for the position im at"
        let raw = "And thanks for the position im at the desk"
        #expect(GhostText.build(typed: typed, raw: raw) == "the desk")
    }

    // MARK: - Clean continuation

    @Test func cleanContinuationDropsTypedPrefix() {
        #expect(GhostText.build(typed: "Thank you for ", raw: "Thank you for shipping.") == "shipping.")
    }

    @Test func userTypedPastModelOutputYieldsEmpty() {
        // User has typed more than the model produced — nothing new to suggest.
        #expect(GhostText.alignedContinuation(typed: "Hello there friend", output: "Hello there") == "")
    }

    @Test func boundaryOverlapContinues() {
        // Model output overlaps the tail of typed and continues past it.
        #expect(GhostText.build(typed: "The quick brown ", raw: "brown fox jumps") == "fox jumps")
    }

    @Test func unrelatedOutputIsRefused() {
        // No alignment at all: refuse rather than dump an unrelated sentence.
        #expect(GhostText.alignedContinuation(typed: "abcdefghij", output: "totally different words") == "")
    }

    // MARK: - Full pipeline (sanitize + align)

    @Test func stripsEmptyThinkBlockAndContinues() {
        let raw = "<think>\n\n</think>\n\nThank you for shipping."
        #expect(GhostText.build(typed: "Thank you for ", raw: raw) == "shipping.")
    }

    @Test func openThinkBlockShowsNothing() {
        #expect(GhostText.build(typed: "Hello", raw: "<think>\nstill reasoning") == "")
    }

    @Test func fillInMiddleReturnsInsertionAsIs() {
        // FIM model returns just the insertion; no prefix-alignment.
        #expect(GhostText.build(typed: "I went to the ", raw: "store", isFillInMiddle: true) == "store")
    }

    // MARK: - Length capping & line truncation (raw continuation)

    @Test func capsToMaxWords() {
        let raw = "and to for all the love and to for all the love"
        #expect(GhostText.build(typed: "", raw: raw, isFillInMiddle: true, maxWords: 4) == "and to for all")
    }

    @Test func keepsOnlyFirstLine() {
        let raw = "your support\nand a new line we don't want"
        #expect(GhostText.build(typed: "", raw: raw, isFillInMiddle: true, maxWords: 0) == "your support")
    }

    @Test func zeroMaxWordsMeansNoCap() {
        let raw = "one two three four five"
        #expect(GhostText.build(typed: "", raw: raw, isFillInMiddle: true, maxWords: 0) == "one two three four five")
    }

    @Test func clampWordsLeavesShortTextAlone() {
        #expect(GhostText.clampWords("just two", 4) == "just two")
    }

    // MARK: - Word-separator spacing (raw continuation)

    @Test func newWordAfterNonSpacePrefixGetsLeadingSpace() {
        // "Is this work" + model " for you" → show/insert " for you" (space before "for").
        #expect(GhostText.build(typed: "Is this work", raw: " for you", isFillInMiddle: true) == " for you")
    }

    @Test func continuingCurrentWordGetsNoLeadingSpace() {
        // "wor" + model "king" → "king" (completes the word, no space).
        #expect(GhostText.build(typed: "wor", raw: "king", isFillInMiddle: true) == "king")
    }

    @Test func newWordAfterSpacePrefixGetsNoExtraSpace() {
        // Prefix already ends with a space → don't double it.
        #expect(GhostText.build(typed: "working for ", raw: " you", isFillInMiddle: true) == "you")
    }
}

@Suite struct CompletionTextSanitizerTests {

    @Test func stripsChatMarkers() {
        #expect(CompletionTextSanitizer.sanitize("<|im_start|>assistant\nhello world") == "hello world")
    }

    @Test func truncatesAtStopToken() {
        #expect(CompletionTextSanitizer.sanitize("hello world<|im_end|>extra") == "hello world")
    }

    @Test func stripsLeadingLabel() {
        #expect(CompletionTextSanitizer.sanitize("Completion: the answer") == "the answer")
    }

    @Test func stripsLeadingPreamble() {
        #expect(CompletionTextSanitizer.sanitize("Sure, here's the completion: done") == "done")
    }

    @Test func stripsCodeFence() {
        #expect(CompletionTextSanitizer.sanitize("```\ncode here\n```") == "code here")
    }

    @Test func stripsGemmaEndOfTurn() {
        #expect(CompletionTextSanitizer.sanitize("nice work<end_of_turn>") == "nice work")
    }

    @Test func nestedScaffoldingStrippedInTwoPasses() {
        #expect(CompletionTextSanitizer.sanitize("<|im_start|>assistant\nCompletion: hi") == "hi")
    }

    @Test func plainTextUnchanged() {
        #expect(CompletionTextSanitizer.sanitize("just normal text") == "just normal text")
    }
}
