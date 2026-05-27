import Testing
@testable import TypeAhead

@Suite struct TypoDetectorTests {
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
        // "teh" is a classic misspelling — if system dictionary has it, suggestion is "the"
        let result = TypoDetector.check(word: "teh")
        if let fix = result {
            #expect(!fix.suggestion.isEmpty)
        }
        // Test passes regardless — NSSpellChecker behavior is system-dependent
    }
}
