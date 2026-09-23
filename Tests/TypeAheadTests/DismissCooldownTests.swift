import Foundation
import Testing
@testable import TypeAhead

/// B2 (Cotypist parity): Escape dismisses the ghost AND briefly pauses suggestions, so the very
/// next keystroke doesn't immediately pop a fresh suggestion for the word the user just rejected.
/// The pause ends at the next word boundary (the user moved on to a new word) or after a cap.
@Suite struct DismissCooldownTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func activeRightAfterDismiss() {
        let c = DismissCooldown(now: t0)
        #expect(c.isActive(now: t0.addingTimeInterval(0.1)))
    }

    @Test func staysActiveWhileTypingLettersOfTheSameWord() {
        var c = DismissCooldown(now: t0)
        c.keystroke("w")
        c.keystroke("o")
        c.keystroke("r")
        #expect(c.isActive(now: t0.addingTimeInterval(1)))
    }

    @Test func endsAtNextWordBoundary() {
        var c = DismissCooldown(now: t0)
        c.keystroke("d")
        c.keystroke(" ")
        #expect(!c.isActive(now: t0.addingTimeInterval(1)))
    }

    @Test func newlineAndSentencePunctuationAreWordBoundaries() {
        for boundary in ["\n", "\r", ".", "!", "?", ",", "\t"] {
            var c = DismissCooldown(now: t0)
            c.keystroke(boundary)
            #expect(!c.isActive(now: t0.addingTimeInterval(0.5)), "boundary \(boundary.debugDescription)")
        }
    }

    @Test func expiresAfterTheCap() {
        let c = DismissCooldown(now: t0, maxDuration: 10)
        #expect(c.isActive(now: t0.addingTimeInterval(9.9)))
        #expect(!c.isActive(now: t0.addingTimeInterval(10)))
    }

    @Test func nonTextKeystrokesDoNotEndIt() {
        var c = DismissCooldown(now: t0)
        c.keystroke(nil)
        c.keystroke("")
        #expect(c.isActive(now: t0.addingTimeInterval(1)))
    }
}
