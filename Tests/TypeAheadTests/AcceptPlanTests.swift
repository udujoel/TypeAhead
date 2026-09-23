import Testing
@testable import TypeAhead

/// `AcceptPlan` decides exactly what text a Tab (next word) or Shift+Tab (whole suggestion)
/// inserts, what gets recorded as accepted, and what ghost remains visible afterwards.
@Suite struct AcceptPlanTests {

    // MARK: - Next word (Tab) — unchanged behavior with the default trailing space

    @Test func nextWordNewWordKeepsLeadingSpaceAndRest() throws {
        let p = try #require(AcceptPlan.make(ghost: " quick brown fox", mode: .nextWord, trailingSpaceAtEnd: true))
        #expect(p.insertion == " quick ")
        #expect(p.acceptedText == "quick")
        #expect(p.remaining == "brown fox")
    }

    @Test func nextWordMidWordCompletionHasNoLeadingSpace() throws {
        let p = try #require(AcceptPlan.make(ghost: "ting the", mode: .nextWord, trailingSpaceAtEnd: true))
        #expect(p.insertion == "ting ")
        #expect(p.remaining == "the")
    }

    @Test func nextWordLastWordGetsTrailingSpaceByDefault() throws {
        let p = try #require(AcceptPlan.make(ghost: " done", mode: .nextWord, trailingSpaceAtEnd: true))
        #expect(p.insertion == " done ")
        #expect(p.remaining.isEmpty)
    }

    // MARK: - B6: "Add a space after accepted words" off

    @Test func lastWordWithoutTrailingSpaceWhenSettingOff() throws {
        let p = try #require(AcceptPlan.make(ghost: "ting", mode: .nextWord, trailingSpaceAtEnd: false))
        #expect(p.insertion == "ting")
    }

    @Test func midSuggestionWordStillSeparatedWhenSettingOff() throws {
        // The remaining ghost ("the") has no leading space of its own, so the separator must
        // still be inserted after a word that isn't the last one.
        let p = try #require(AcceptPlan.make(ghost: "ting the", mode: .nextWord, trailingSpaceAtEnd: false))
        #expect(p.insertion == "ting ")
        #expect(p.remaining == "the")
    }

    // MARK: - A7: whole suggestion (Shift+Tab)

    @Test func allInsertsWholeGhostAndLeavesNothing() throws {
        let p = try #require(AcceptPlan.make(ghost: " quick brown fox", mode: .all, trailingSpaceAtEnd: true))
        #expect(p.insertion == " quick brown fox ")
        #expect(p.acceptedText == "quick brown fox")
        #expect(p.remaining.isEmpty)
    }

    @Test func allRespectsTrailingSpaceSetting() throws {
        let p = try #require(AcceptPlan.make(ghost: "ting the report.", mode: .all, trailingSpaceAtEnd: false))
        #expect(p.insertion == "ting the report.")
    }

    @Test func allDoesNotDoubleATrailingSpaceInTheGhost() throws {
        let p = try #require(AcceptPlan.make(ghost: " see you ", mode: .all, trailingSpaceAtEnd: true))
        #expect(p.insertion == " see you ")
    }

    // MARK: - Degenerate ghosts

    @Test func emptyOrWhitespaceGhostHasNoPlan() {
        #expect(AcceptPlan.make(ghost: "", mode: .nextWord, trailingSpaceAtEnd: true) == nil)
        #expect(AcceptPlan.make(ghost: "   ", mode: .nextWord, trailingSpaceAtEnd: true) == nil)
        #expect(AcceptPlan.make(ghost: " ", mode: .all, trailingSpaceAtEnd: true) == nil)
    }
}
