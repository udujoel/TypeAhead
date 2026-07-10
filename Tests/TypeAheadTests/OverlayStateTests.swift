import Testing
@testable import TypeAhead

@Suite("OverlayMode / OverlayStateMachine")
struct OverlayStateTests {

    // MARK: - Show

    @Test func showMLProducesMLCompletionMode() {
        let mode = OverlayStateMachine.showML(ghost: "hello", epoch: 3)
        #expect(mode == .mlCompletion(ghost: "hello", epoch: 3))
        #expect(mode.ghost == "hello")
        #expect(mode.isVisible)
    }

    @Test func showSpellProducesSpellCorrectionMode() {
        let mode = OverlayStateMachine.showSpell(ghost: "hello", replaceLen: 4, epoch: 1)
        #expect(mode == .spellCorrection(ghost: "hello", replaceLen: 4, epoch: 1))
        #expect(mode.ghost == "hello")
    }

    @Test func showEmojiProducesEmojiMode() {
        let mode = OverlayStateMachine.showEmoji(ghost: "👋", replaceLen: 5, epoch: 2)
        #expect(mode == .emoji(ghost: "👋", replaceLen: 5, epoch: 2))
        #expect(mode.ghost == "👋")
    }

    @Test func hiddenModeGhostIsEmptyAndNotVisible() {
        #expect(OverlayMode.hidden.ghost == "")
        #expect(!OverlayMode.hidden.isVisible)
    }

    // MARK: - Keystroke: hidden

    @Test func keystrokeOnHiddenAlwaysDiverges() {
        #expect(OverlayStateMachine.keystroke(mode: .hidden, typedChar: "a") == .diverged)
        #expect(OverlayStateMachine.keystroke(mode: .hidden, typedChar: nil) == .diverged)
    }

    // MARK: - Keystroke: spell correction never type-throughs

    @Test func keystrokeOnSpellCorrectionAlwaysDivergesEvenOnMatchingPrefix() {
        let mode = OverlayMode.spellCorrection(ghost: "hello", replaceLen: 4, epoch: 0)
        // Even though "h" matches the ghost's first character, spell corrections are
        // replacements, not insertions — type-through must never apply.
        #expect(OverlayStateMachine.keystroke(mode: mode, typedChar: "h") == .diverged)
        #expect(OverlayStateMachine.keystroke(mode: mode, typedChar: "x") == .diverged)
    }

    // MARK: - Keystroke: ML completion type-through

    @Test func keystrokeOnMLCompletionAdvancesOnMatchingPrefix() {
        let mode = OverlayMode.mlCompletion(ghost: "hello", epoch: 5)
        let outcome = OverlayStateMachine.keystroke(mode: mode, typedChar: "h")
        #expect(outcome == .advanced(newMode: .mlCompletion(ghost: "ello", epoch: 5)))
    }

    @Test func keystrokeOnMLCompletionFinalCharacterTypesThroughToEmpty() {
        let mode = OverlayMode.mlCompletion(ghost: "o", epoch: 5)
        let outcome = OverlayStateMachine.keystroke(mode: mode, typedChar: "o")
        #expect(outcome == .typedThroughToEmpty)
    }

    @Test func keystrokeOnMLCompletionDivergesOnMismatch() {
        let mode = OverlayMode.mlCompletion(ghost: "hello", epoch: 5)
        let outcome = OverlayStateMachine.keystroke(mode: mode, typedChar: "x")
        #expect(outcome == .diverged)
    }

    @Test func keystrokeOnMLCompletionDivergesOnMultiCharInput() {
        // Multi-char input (paste, IME commit) is not a plain length-1 insertion — diverge.
        let mode = OverlayMode.mlCompletion(ghost: "hello", epoch: 5)
        let outcome = OverlayStateMachine.keystroke(mode: mode, typedChar: "he")
        #expect(outcome == .diverged)
    }

    @Test func keystrokeOnMLCompletionDivergesOnNilTypedChar() {
        let mode = OverlayMode.mlCompletion(ghost: "hello", epoch: 5)
        #expect(OverlayStateMachine.keystroke(mode: mode, typedChar: nil) == .diverged)
    }

    // MARK: - Keystroke: emoji type-through

    @Test func keystrokeOnEmojiAdvancesAndPreservesReplaceLenAndEpoch() {
        let mode = OverlayMode.emoji(ghost: "ab", replaceLen: 5, epoch: 7)
        let outcome = OverlayStateMachine.keystroke(mode: mode, typedChar: "a")
        #expect(outcome == .advanced(newMode: .emoji(ghost: "b", replaceLen: 5, epoch: 7)))
    }

    @Test func keystrokeOnEmojiFinalCharacterTypesThroughToEmpty() {
        let mode = OverlayMode.emoji(ghost: "b", replaceLen: 5, epoch: 7)
        #expect(OverlayStateMachine.keystroke(mode: mode, typedChar: "b") == .typedThroughToEmpty)
    }

    @Test func keystrokeOnEmojiDivergesOnMismatch() {
        let mode = OverlayMode.emoji(ghost: "ab", replaceLen: 5, epoch: 7)
        #expect(OverlayStateMachine.keystroke(mode: mode, typedChar: "z") == .diverged)
    }

    // MARK: - Hide (escape / focus change)

    @Test func hideReturnsHiddenUnconditionally() {
        #expect(OverlayStateMachine.hide() == .hidden)
    }

    // MARK: - Accept: tabKeyDisabled passthrough wins regardless of mode/epoch

    @Test func acceptRequestedTabKeyDisabledAlwaysPassesThroughEvenWithFreshGhost() {
        let mode = OverlayMode.mlCompletion(ghost: "hello", epoch: 1)
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: 1, tabKeyDisabled: true)
        #expect(outcome == .passThrough)
    }

    @Test func acceptRequestedTabKeyDisabledPassesThroughEvenWhenHidden() {
        let outcome = OverlayStateMachine.acceptRequested(mode: .hidden, currentEpoch: 0, tabKeyDisabled: true)
        #expect(outcome == .passThrough)
    }

    // MARK: - Accept: hidden

    @Test func acceptRequestedOnHiddenIsNone() {
        let outcome = OverlayStateMachine.acceptRequested(mode: .hidden, currentEpoch: 0, tabKeyDisabled: false)
        #expect(outcome == .none)
    }

    // MARK: - Accept: ML completion

    @Test func acceptRequestedOnMLCompletionWithMatchingEpochAcceptsWord() {
        let mode = OverlayMode.mlCompletion(ghost: "hello world", epoch: 3)
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: 3, tabKeyDisabled: false)
        #expect(outcome == .acceptWord(ghost: "hello world"))
    }

    @Test func acceptRequestedOnMLCompletionWithStaleEpochIsNone() {
        let mode = OverlayMode.mlCompletion(ghost: "hello world", epoch: 3)
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: 4, tabKeyDisabled: false)
        #expect(outcome == .none)
    }

    // MARK: - Accept: spell correction

    @Test func acceptRequestedOnSpellCorrectionWithMatchingEpochReplacesSpell() {
        let mode = OverlayMode.spellCorrection(ghost: "hello", replaceLen: 4, epoch: 2)
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: 2, tabKeyDisabled: false)
        #expect(outcome == .replaceSpell(ghost: "hello", replaceLen: 4))
    }

    @Test func acceptRequestedOnSpellCorrectionWithStaleEpochIsNone() {
        let mode = OverlayMode.spellCorrection(ghost: "hello", replaceLen: 4, epoch: 2)
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: 99, tabKeyDisabled: false)
        #expect(outcome == .none)
    }

    // MARK: - Accept: emoji

    @Test func acceptRequestedOnEmojiWithMatchingEpochReplacesEmoji() {
        let mode = OverlayMode.emoji(ghost: "👋", replaceLen: 5, epoch: 6)
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: 6, tabKeyDisabled: false)
        #expect(outcome == .replaceEmoji(ghost: "👋", replaceLen: 5))
    }

    @Test func acceptRequestedOnEmojiWithStaleEpochIsNone() {
        let mode = OverlayMode.emoji(ghost: "👋", replaceLen: 5, epoch: 6)
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: 7, tabKeyDisabled: false)
        #expect(outcome == .none)
    }
}
