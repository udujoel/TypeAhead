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

    // MARK: - Punctuation spacing

    @Test func closingPunctuationGetsNoLeadingSpace() {
        // "How are you" + model " ?" → show "?" (no space), giving "How are you?"
        #expect(GhostText.build(typed: "How are you", raw: " ?", isFillInMiddle: true) == "?")
    }

    @Test func exclamationGetsNoLeadingSpace() {
        // "What a day" + model " !" → "!" not " !"
        #expect(GhostText.build(typed: "What a day", raw: " !", isFillInMiddle: true) == "!")
    }

    @Test func closingParenGetsNoLeadingSpace() {
        // "(note about this" + model " )" → ")" attaches directly
        #expect(GhostText.build(typed: "(note about this", raw: " )", isFillInMiddle: true) == ")")
    }

    @Test func questionMarkWithoutLeadingSpaceInRaw() {
        // Model outputs "?" without a leading space — also fine (rawBeginsNewWord=false, no space added)
        #expect(GhostText.build(typed: "How are you", raw: "?", isFillInMiddle: true) == "?")
    }

    @Test func openingQuoteGetsLeadingSpace() {
        // An opening quote begins a new token — it must get a leading space like any new word.
        // Regression for: quotes in closingPunctuation caused "He said"hello" (missing space).
        let ghost = GhostText.build(typed: "He said", raw: " \"hello", isFillInMiddle: true)
        #expect(ghost.hasPrefix(" "))
    }

    @Test func openingSingleQuoteGetsLeadingSpace() {
        // Single quote used as an opening quotation mark should also get a leading space.
        let ghost = GhostText.build(typed: "She replied", raw: " 'yes", isFillInMiddle: true)
        #expect(ghost.hasPrefix(" "))
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

// MARK: - Ghost quality gate

@Suite struct GhostTextStreamingStopTests {
    // The overlay only ever shows the first line, capped at `maxWords`. Once the model has
    // produced a complete first line (a newline after real content) or more than `maxWords`
    // words, further tokens can't change the display — so streaming can stop early (snappier,
    // less battery). These pin that pure decision.

    @Test func doesNotStopOnEmptyOutput() {
        #expect(GhostText.shouldStopStreaming(raw: "", maxWords: 4) == false)
        #expect(GhostText.shouldStopStreaming(raw: "   ", maxWords: 4) == false)
    }

    @Test func doesNotStopMidFirstLine() {
        #expect(GhostText.shouldStopStreaming(raw: "going to the", maxWords: 4) == false)
    }

    @Test func stopsWhenFirstLineCompletesWithNewline() {
        // Real content followed by a newline — the displayed first line is final.
        #expect(GhostText.shouldStopStreaming(raw: "going to the store\nand then", maxWords: 20) == true)
    }

    @Test func doesNotStopOnLeadingNewlinesBeforeContent() {
        // Small models often emit a blank line or two before any real words. A newline that
        // precedes all content must NOT stop us — we have nothing to show yet.
        #expect(GhostText.shouldStopStreaming(raw: "\n\nHello", maxWords: 20) == false)
    }

    @Test func stopsWhenWordCapExceeded() {
        // 5 words on the first line with maxWords 4 — the first 4 are complete, the rest is clamped.
        #expect(GhostText.shouldStopStreaming(raw: "one two three four five", maxWords: 4) == true)
    }

    @Test func doesNotStopAtExactWordCap() {
        // Exactly maxWords words and no trailing boundary — the last word may still be growing
        // ("four" → "fourteen"), so keep streaming until a further word or newline arrives.
        #expect(GhostText.shouldStopStreaming(raw: "one two three four", maxWords: 4) == false)
    }

    @Test func noWordCapWhenMaxWordsZero() {
        // maxWords == 0 means "no cap" — only a completed first line stops streaming.
        #expect(GhostText.shouldStopStreaming(raw: "one two three four five six seven", maxWords: 0) == false)
    }
}

@Suite struct GhostTextQualityTests {

    @Test func rejectsLoneBackslash() {
        #expect(!GhostText.isUsableGhost("\\"))
        #expect(!GhostText.isUsableGhost("\\\\"))
    }

    @Test func rejectsLeadingHyphenWord() {
        // "-working" arises when model continues "co" → "co-working"; reject it.
        #expect(!GhostText.isUsableGhost("-working"))
        #expect(!GhostText.isUsableGhost("-based"))
    }

    @Test func allowsHyphenatedWordMidGhost() {
        // "well-defined" is a valid compound — the hyphen is mid-word, not leading.
        #expect(GhostText.isUsableGhost("well-defined"))
    }

    @Test func rejectsPurePunctuation() {
        // Commas, ellipses, and other mid-sentence punctuation without letters are not useful.
        #expect(!GhostText.isUsableGhost(","))
        #expect(!GhostText.isUsableGhost("..."))
        #expect(!GhostText.isUsableGhost(":"))
        #expect(!GhostText.isUsableGhost("--"))
    }

    @Test func allowsStandaloneTerminalPunctuation() {
        // ?, !, ), ], } are useful on their own — the model suggests them to close a sentence/bracket.
        #expect(GhostText.isUsableGhost("?"))
        #expect(GhostText.isUsableGhost("!"))
        #expect(GhostText.isUsableGhost(")"))
        #expect(GhostText.isUsableGhost("]"))
        #expect(GhostText.isUsableGhost("}"))
    }

    @Test func allowsPunctuationFollowedByWord() {
        // ". It lets me" — starts with period but has letters, so valid.
        #expect(GhostText.isUsableGhost(". It lets me"))
        #expect(GhostText.isUsableGhost(". That is"))
    }

    @Test func allowsNormalCompletions() {
        #expect(GhostText.isUsableGhost("coding is fun"))
        #expect(GhostText.isUsableGhost("ting "))     // suffix of "Wri" → "Writing"
        #expect(GhostText.isUsableGhost("solutions for real problems"))
    }

    @Test func rejectsEmpty() {
        #expect(!GhostText.isUsableGhost(""))
        #expect(!GhostText.isUsableGhost("   "))
    }

    // End-to-end: backslash raw output becomes empty ghost via build()
    @Test func buildFiltersBackslashRaw() {
        let ghost = GhostText.build(typed: "I love c", raw: "\\\n", isFillInMiddle: true, maxWords: 4)
        #expect(ghost.isEmpty)
    }

    // End-to-end: leading-hyphen output becomes empty ghost via build()
    @Test func buildFiltersLeadingHyphen() {
        let ghost = GhostText.build(
            typed: "I love co",
            raw: "-working spaces. They offer",
            isFillInMiddle: true,
            maxWords: 4
        )
        #expect(ghost.isEmpty)
    }
}
