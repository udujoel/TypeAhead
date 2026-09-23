import Foundation
import Testing
@testable import TypeAhead

@Suite("CompletionCoordinator")
struct CompletionCoordinatorTests {

    // MARK: - Policy-disabled early exit

    @Test func shouldRunCycleTrueWhenPolicyEnabled() {
        let policy = ResolvedPolicy(completionsEnabled: true, tabKeyDisabled: false, styleInstruction: nil, recordHistory: true, compatibilityMode: false)
        #expect(CompletionCoordinator.shouldRunCycle(policy: policy))
    }

    @Test func shouldRunCycleFalseWhenPolicyDisabled() {
        let policy = ResolvedPolicy(completionsEnabled: false, tabKeyDisabled: false, styleInstruction: nil, recordHistory: true, compatibilityMode: false)
        #expect(!CompletionCoordinator.shouldRunCycle(policy: policy))
    }

    // MARK: - Fast-path selection order

    @Test func selectFastPathPrefersSpellOverEmojiWhenBothPresent() {
        let fix = TypoFix(original: "teh", suggestion: "the", misspelledLength: 3)
        let outcome = CompletionCoordinator.selectFastPath(spellFix: fix, emojiShortcode: "wave", emojiMatch: "👋")
        #expect(outcome == .spell(fix))
    }

    @Test func selectFastPathUsesEmojiWhenNoSpellFix() {
        let outcome = CompletionCoordinator.selectFastPath(spellFix: nil, emojiShortcode: "wave", emojiMatch: "👋")
        #expect(outcome == .emoji(shortcode: "wave", emoji: "👋"))
    }

    @Test func selectFastPathNoneWhenNeitherPresent() {
        let outcome = CompletionCoordinator.selectFastPath(spellFix: nil, emojiShortcode: nil, emojiMatch: nil)
        #expect(outcome == .none)
    }

    @Test func selectFastPathNoneWhenEmojiShortcodePresentButNoMatch() {
        // shortcode typed but no catalog entry matched — must not fall through to a nonsense
        // emoji outcome missing its text.
        let outcome = CompletionCoordinator.selectFastPath(spellFix: nil, emojiShortcode: "xyz", emojiMatch: nil)
        #expect(outcome == .none)
    }

    // MARK: - Second-word gating (WP-B)

    @Test func shouldAttemptCompletionFalseForZeroWords() {
        #expect(!CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: ""))
        #expect(!CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "   "))
    }

    @Test func shouldAttemptCompletionFalseForOneWord() {
        #expect(!CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "Hello"))
        #expect(!CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "Hello "))
    }

    @Test func shouldAttemptCompletionTrueForTwoOrMoreWords() {
        #expect(CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "Hello world"))
        #expect(CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "I went home. Then I"))
    }

    @Test func shouldAttemptCompletionIgnoresPunctuationOnlyTokens() {
        // "-" and "..." are whitespace-separated tokens but contain no letter/digit, so they
        // don't count toward the 2-word minimum.
        #expect(!CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "Hello - ..."))
        #expect(CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "Hello - world"))
    }

    @Test func shouldAttemptCompletionTrueAtSentenceEndWithTwoOrMoreWords() {
        // WP-B: unlike the old shouldSuppressAtSentenceEnd guard, sentence-final punctuation no
        // longer blocks an attempt once the 2-word floor is met.
        #expect(CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "I went home."))
        #expect(CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: "How are you?"))
    }

    // MARK: - Retry-once on unusable generation (WP-B)

    @Test func shouldRetryGenerationTrueOnFirstAttemptWithNoUsableGhost() {
        #expect(CompletionCoordinator.shouldRetryGeneration(attempt: 0, producedUsableGhost: false))
    }

    @Test func shouldRetryGenerationFalseOnFirstAttemptWithUsableGhost() {
        #expect(!CompletionCoordinator.shouldRetryGeneration(attempt: 0, producedUsableGhost: true))
    }

    @Test func shouldRetryGenerationFalseOnSecondAttemptRegardlessOfOutcome() {
        // Never retry more than once.
        #expect(!CompletionCoordinator.shouldRetryGeneration(attempt: 1, producedUsableGhost: false))
        #expect(!CompletionCoordinator.shouldRetryGeneration(attempt: 1, producedUsableGhost: true))
    }

    // MARK: - Screen-context cache TTL

    @Test func shouldUseCachedScreenContextTrueWithinTTLAndSameApp() {
        let now = Date()
        let cache = CompletionCoordinator.ScreenContextCache(text: "hello", at: now.addingTimeInterval(-1), bundleID: "com.app")
        #expect(CompletionCoordinator.shouldUseCachedScreenContext(cache: cache, now: now, ttl: 2.0, currentBundleID: "com.app"))
    }

    @Test func shouldUseCachedScreenContextFalseWhenExpired() {
        let now = Date()
        let cache = CompletionCoordinator.ScreenContextCache(text: "hello", at: now.addingTimeInterval(-3), bundleID: "com.app")
        #expect(!CompletionCoordinator.shouldUseCachedScreenContext(cache: cache, now: now, ttl: 2.0, currentBundleID: "com.app"))
    }

    @Test func shouldUseCachedScreenContextFalseWhenDifferentApp() {
        let now = Date()
        let cache = CompletionCoordinator.ScreenContextCache(text: "hello", at: now.addingTimeInterval(-1), bundleID: "com.app.a")
        #expect(!CompletionCoordinator.shouldUseCachedScreenContext(cache: cache, now: now, ttl: 2.0, currentBundleID: "com.app.b"))
    }

    @Test func shouldUseCachedScreenContextFalseWhenNoCache() {
        #expect(!CompletionCoordinator.shouldUseCachedScreenContext(cache: nil, now: Date(), ttl: 2.0, currentBundleID: "com.app"))
    }

    @Test func shouldUseCachedScreenContextFalseExactlyAtTTLBoundary() {
        // now.timeIntervalSince(at) == ttl exactly — the original check is strict `<`, so the
        // boundary itself must NOT be considered fresh.
        let at = Date()
        let now = at.addingTimeInterval(2.0)
        let cache = CompletionCoordinator.ScreenContextCache(text: "hello", at: at, bundleID: "com.app")
        #expect(!CompletionCoordinator.shouldUseCachedScreenContext(cache: cache, now: now, ttl: 2.0, currentBundleID: "com.app"))
    }

    // MARK: - B7: mid-line completions toggle

    @Test func notMidLineAtEndOfText() {
        #expect(!CompletionCoordinator.isMidLine(textAfterCursor: ""))
    }

    @Test func notMidLineWhenOnlyWhitespaceFollowsOnThisLine() {
        #expect(!CompletionCoordinator.isMidLine(textAfterCursor: "   "))
        #expect(!CompletionCoordinator.isMidLine(textAfterCursor: "  \nNext paragraph"))
    }

    @Test func midLineWhenWordsFollowOnThisLine() {
        #expect(CompletionCoordinator.isMidLine(textAfterCursor: " and more"))
        #expect(CompletionCoordinator.isMidLine(textAfterCursor: "tail\nnext"))
    }

    @Test func midLineGateOnlyBlocksWhenSettingIsOff() {
        #expect(CompletionCoordinator.passesMidLineGate(midLineEnabled: true, textAfterCursor: " more"))
        #expect(!CompletionCoordinator.passesMidLineGate(midLineEnabled: false, textAfterCursor: " more"))
        #expect(CompletionCoordinator.passesMidLineGate(midLineEnabled: false, textAfterCursor: "\nmore"))
    }
}
