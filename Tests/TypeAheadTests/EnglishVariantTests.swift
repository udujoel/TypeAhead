import AppKit
import Testing
@testable import TypeAhead

/// The English-variant setting picks one dictionary for the spell/word-completion fast paths and
/// one spelling sentence for the model, so the two never disagree (Cotypist Labs "British English").
@Suite struct EnglishVariantTests {

    @Test func spellCheckerLanguagePerVariant() {
        #expect(EnglishVariant.automatic.spellCheckerLanguage(systemLanguage: "en_AU") == "en_AU")
        #expect(EnglishVariant.american.spellCheckerLanguage(systemLanguage: "en_GB") == "en")
        #expect(EnglishVariant.british.spellCheckerLanguage(systemLanguage: "en") == "en_GB")
    }

    @Test func britishSpellingPerVariant() {
        #expect(EnglishVariant.british.usesBritishSpelling(systemLanguage: "en"))
        #expect(!EnglishVariant.american.usesBritishSpelling(systemLanguage: "en_GB"))
        #expect(EnglishVariant.automatic.usesBritishSpelling(systemLanguage: "en_GB"))
        #expect(EnglishVariant.automatic.usesBritishSpelling(systemLanguage: "en_AU"))
        #expect(!EnglishVariant.automatic.usesBritishSpelling(systemLanguage: "en"))
        #expect(!EnglishVariant.automatic.usesBritishSpelling(systemLanguage: "en_US"))
    }

    @Test func instructionMentionsBritishSpellingOnlyWhenAsked() {
        let british = PersonalizationEngine.baseInstruction(targetWords: 4, britishSpelling: true)
        let plain = PersonalizationEngine.baseInstruction(targetWords: 4)
        #expect(british.contains("British spelling"))
        #expect(!plain.contains("British"))
        #expect(plain.contains("Write only in English. Never reply"))
    }

    @Test func buildInstructionThreadsBritishSpelling() {
        let text = PersonalizationEngine.buildInstruction(personaNote: "Note", targetWords: 4, britishSpelling: true)
        #expect(text.hasPrefix("Note\n\n"))
        #expect(text.contains("British spelling"))
    }

    @Test(.enabled(if: NSSpellChecker.shared.availableLanguages.contains("en_GB")))
    func typoDetectorFollowsTheChosenDictionary() {
        #expect(TypoDetector.check(word: "colour", language: "en_GB") == nil)
        #expect(TypoDetector.check(word: "colour", language: "en") != nil)
    }
}
