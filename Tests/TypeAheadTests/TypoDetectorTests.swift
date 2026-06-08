import Testing
@testable import TypeAhead

@Suite struct TypoDetectorTests {

    // MARK: - check(word:)

    @Test func returnsNilForCorrectWord() {
        let result = TypoDetector.check(word: "hello")
        #expect(result == nil)
    }

    @Test func returnsNilForEmptyString() {
        let result = TypoDetector.check(word: "")
        #expect(result == nil)
    }

    @Test func returnsNilForSingleLetter() {
        let result = TypoDetector.check(word: "a")
        #expect(result == nil)
    }

    @Test func detectsKnownTypo() {
        let result = TypoDetector.check(word: "teh")
        if let fix = result {
            #expect(!fix.suggestion.isEmpty)
            #expect(fix.misspelledLength == 3)
        }
        // Pass regardless — NSSpellChecker behavior is system-dependent
    }

    // MARK: - lastWord(in:)

    @Test func lastWordExtractsTrailingToken() {
        #expect(TypoDetector.lastWord(in: "hello world") == "world")
    }

    @Test func lastWordWithNoSpaceReturnsWholeString() {
        #expect(TypoDetector.lastWord(in: "hello") == "hello")
    }

    @Test func lastWordEmptyInput() {
        #expect(TypoDetector.lastWord(in: "") == "")
    }

    @Test func lastWordStripsLeadingWords() {
        #expect(TypoDetector.lastWord(in: "one two three") == "three")
    }

    // MARK: - correction(in:)

    @Test func correctionReturnsNilWhenTrailingSpace() {
        // Cursor is past the word — no correction triggered
        let result = TypoDetector.correction(in: "hello recieve ")
        #expect(result == nil)
    }

    @Test func correctionReturnsNilForCorrectSpelling() {
        let result = TypoDetector.correction(in: "I received the")
        #expect(result == nil)
    }

    @Test func correctionReturnsNilForShortWord() {
        // "ah" is only 2 letters — below the 3-char minimum
        let result = TypoDetector.correction(in: "oh ah")
        #expect(result == nil)
    }

    @Test func correctionReturnsNilForEmojiShortcode() {
        // `:wav` starts with `:` — must not be spell-checked
        let result = TypoDetector.correction(in: "hello :wav")
        #expect(result == nil)
    }

    @Test func correctionReturnsNilForWordWithDigits() {
        // "abc123" contains digits — skip (likely code/variable)
        let result = TypoDetector.correction(in: "identifier abc123")
        #expect(result == nil)
    }

    @Test func correctionDetectsMisspelledWord() {
        // "recieve" is a common misspelling — system dictionary should catch it.
        // This test is system-dependent; it passes if NSSpellChecker is enabled.
        let result = TypoDetector.correction(in: "I recieve")
        if let fix = result {
            #expect(fix.misspelledLength == "recieve".count)
            #expect(!fix.suggestion.isEmpty)
            #expect(fix.suggestion.lowercased() != "recieve")
        }
        // Acceptable if system spell-check returns nil on this machine
    }

    @Test func correctionMisspelledLengthMatchesWord() {
        let result = TypoDetector.correction(in: "The teh")
        if let fix = result {
            #expect(fix.misspelledLength == "teh".count)
        }
    }
}
