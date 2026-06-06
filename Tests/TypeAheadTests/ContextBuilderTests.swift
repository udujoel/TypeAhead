import Testing
@testable import TypeAhead

@Suite struct ContextBuilderTests {
    // ContextBuilder now returns the trimmed text before the cursor and intentionally
    // excludes clipboard/history (small models complete better from a focused prompt).
    // Fill-in-middle prompting moved into InferenceEngine; ContextBuilder only supplies
    // the trimmed prefix and (for FIM) the trimmed suffix.

    @Test func returnsTextBeforeCursor() {
        let ctx = TextContext(
            textBeforeCursor: "Hello",
            textAfterCursor: "",
            appName: "Notes",
            windowTitle: "My Note"
        )
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        #expect(result.contains("Hello"))
        #expect(!result.contains("<|fim_prefix|>"))
    }

    @Test func trimsToCurrentSentence() {
        let ctx = TextContext(
            textBeforeCursor: "First sentence is done. Now the second",
            textAfterCursor: "",
            appName: "Notes",
            windowTitle: ""
        )
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        #expect(result == "Now the second")
    }

    @Test func capsPrefixLength() {
        let longText = String(repeating: "a", count: 500)
        let ctx = TextContext(textBeforeCursor: longText, textAfterCursor: "", appName: "Mail", windowTitle: "")
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        #expect(result.count <= 160)
    }

    @Test func clipboardAndHistoryAreExcluded() {
        let ctx = TextContext(textBeforeCursor: "Some text", textAfterCursor: "", appName: "Slack", windowTitle: "")
        let result = ContextBuilder.buildPrompt(
            context: ctx,
            clipboard: "SECRET-CLIPBOARD",
            history: ["PAST-HISTORY"],
            customInstructions: ""
        )
        #expect(!result.contains("SECRET-CLIPBOARD"))
        #expect(!result.contains("PAST-HISTORY"))
    }

    // MARK: - buildSuffix (fill-in-middle)

    @Test func suffixEmptyAtEndOfText() {
        let ctx = TextContext(textBeforeCursor: "Hello world", textAfterCursor: "", appName: "Notes", windowTitle: "")
        #expect(ContextBuilder.buildSuffix(context: ctx).isEmpty)
    }

    @Test func suffixTrimsToSentenceBoundary() {
        let ctx = TextContext(
            textBeforeCursor: "I went to the ",
            textAfterCursor: "yesterday. Then I came home.",
            appName: "Notes",
            windowTitle: ""
        )
        #expect(ContextBuilder.buildSuffix(context: ctx) == "yesterday.")
    }
}
