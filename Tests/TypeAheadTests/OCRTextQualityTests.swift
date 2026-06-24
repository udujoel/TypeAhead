import Testing
@testable import TypeAhead

/// Tests for OCR garble detection — rejecting the letter-substitution junk that fast Vision OCR
/// produces from app UI (e.g. "SIiow4(s Liie aciive 1110(Ael k<eady") before it poisons the
/// completion prompt.
@Suite struct OCRTextQualityTests {

    // MARK: - Real text passes

    @Test func cleanProseIsReadable() {
        #expect(OCRTextQuality.isLikelyReadable("Meeting notes for the quarterly review"))
    }

    @Test func structuredFinancialTextIsReadable() {
        // Symbols attach cleanly to real words — this is legitimate context, not garble.
        #expect(OCRTextQuality.isLikelyReadable("Q3 Report – Total: $4.2M"))
    }

    @Test func textWithHyphensAndApostrophesIsReadable() {
        #expect(OCRTextQuality.isLikelyReadable("Well-defined plans don't fail"))
    }

    // MARK: - Garble is rejected

    @Test func letterSubstitutionGarbleIsRejected() {
        // Real captured failure: "header line Shows the active model Ready" OCR'd badly.
        #expect(!OCRTextQuality.isLikelyReadable("ader line SIiow4(s Liie aciive 1110(Ael * k<eady\"I"))
    }

    @Test func symbolSoupIsRejected() {
        #expect(!OCRTextQuality.isLikelyReadable("••• Ll8?.G•..."))
    }

    @Test func emptyOrWhitespaceIsRejected() {
        #expect(!OCRTextQuality.isLikelyReadable(""))
        #expect(!OCRTextQuality.isLikelyReadable("   \n  "))
    }

    // MARK: - isGarbledToken (the core signal)

    @Test func tokenWithInteriorDigitOrSymbolIsGarbled() {
        #expect(OCRTextQuality.isGarbledToken("SIiow4(s"))
        #expect(OCRTextQuality.isGarbledToken("1110(Ael"))
        #expect(OCRTextQuality.isGarbledToken("k<eady\"I"))
    }

    @Test func cleanTokensAreNotGarbled() {
        #expect(!OCRTextQuality.isGarbledToken("active"))
        #expect(!OCRTextQuality.isGarbledToken("Q3"))        // trailing digit, no letter after
        #expect(!OCRTextQuality.isGarbledToken("$4.2M"))     // symbols not wedged between letters
        #expect(!OCRTextQuality.isGarbledToken("Total:"))    // trailing colon
        #expect(!OCRTextQuality.isGarbledToken("well-defined"))
        #expect(!OCRTextQuality.isGarbledToken("don't"))
    }
}
