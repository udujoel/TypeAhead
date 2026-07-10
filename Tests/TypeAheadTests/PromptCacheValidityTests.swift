import Testing
@testable import TypeAhead

@Suite("PromptCacheValidity")
struct PromptCacheValidityTests {

    @Test("no cached tokens yet -> rebuild")
    func emptyCacheRebuilds() {
        let decision = PromptCacheValidity.decide(cachedTokens: [], newTokens: [1, 2, 3])
        #expect(decision == .rebuild)
    }

    @Test("identical tokens -> rebuild (nothing new to append)")
    func identicalTokensRebuilds() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3], newTokens: [1, 2, 3])
        #expect(decision == .rebuild)
    }

    @Test("new prompt shorter than cached -> rebuild")
    func shorterNewPromptRebuilds() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3, 4], newTokens: [1, 2, 3])
        #expect(decision == .rebuild)
    }

    @Test("new prompt is a strict extension of cached -> reuse with correct delta")
    func strictExtensionReuses() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3], newTokens: [1, 2, 3, 4, 5])
        #expect(decision == .reuse(deltaTokens: [4, 5]))
    }

    @Test("single new token appended -> reuse with one-token delta")
    func singleTokenAppendReuses() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3], newTokens: [1, 2, 3, 9])
        #expect(decision == .reuse(deltaTokens: [9]))
    }

    @Test("divergence mid-sequence (edit changed already-typed text) -> rebuild")
    func midSequenceDivergenceRebuilds() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3], newTokens: [1, 9, 3, 4])
        #expect(decision == .rebuild)
    }

    @Test("divergence at token 0 (instruction changed, e.g. suffix/persona edit) -> rebuild")
    func instructionChangeRebuilds() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3], newTokens: [9, 2, 3, 4])
        #expect(decision == .rebuild)
    }

    @Test("longer cached than new but overlapping prefix -> rebuild")
    func longerCachedThanNewRebuilds() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3, 4, 5], newTokens: [1, 2, 3])
        #expect(decision == .rebuild)
    }

    @Test("empty new tokens -> rebuild")
    func emptyNewTokensRebuilds() {
        let decision = PromptCacheValidity.decide(cachedTokens: [1, 2, 3], newTokens: [])
        #expect(decision == .rebuild)
    }
}
