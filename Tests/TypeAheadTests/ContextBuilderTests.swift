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

    @Test func trimsToCurrentSentenceWhenTailIsLongEnough() {
        // "Now I am writing the second sentence here" = 41 chars >= minTailChars (25).
        // Tail is long enough to stand alone — trim to it.
        let ctx = TextContext(
            textBeforeCursor: "First sentence is done. Now I am writing the second sentence here",
            textAfterCursor: "",
            appName: "Notes",
            windowTitle: ""
        )
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        #expect(result == "Now I am writing the second sentence here")
    }

    @Test func keepsFullContextWhenTailIsTooShort() {
        // "Now the second" = 14 chars < 25 — too short to stand alone.
        // Full prefix is kept so the model has context from the prior sentence.
        let ctx = TextContext(
            textBeforeCursor: "First sentence is done. Now the second",
            textAfterCursor: "",
            appName: "Notes",
            windowTitle: ""
        )
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        // Should contain the prior sentence as context, not just the 14-char tail.
        #expect(result.contains("First sentence"))
        #expect(result.contains("Now the second"))
    }

    @Test func keepsContextForNewParagraph() {
        // Simulates starting a new paragraph after existing text.
        // The new line "I love c" (8 chars) is far below minTailChars (25),
        // so the model gets the full prior context, not just "I love c".
        let ctx = TextContext(
            textBeforeCursor: "Software design is my passion.\n\nI love c",
            textAfterCursor: "",
            appName: "TextEdit",
            windowTitle: ""
        )
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        #expect(result.contains("Software design"))
        #expect(result.contains("I love c"))
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

    // MARK: - screenContext injection

    @Test func screenContextPrependsHint() {
        let ctx = TextContext(textBeforeCursor: "The revenue was", textAfterCursor: "", appName: "Numbers", windowTitle: "")
        let result = ContextBuilder.buildPrompt(
            context: ctx, clipboard: nil, history: [], customInstructions: "",
            screenContext: "Q3 Report – Total: $4.2M"
        )
        #expect(result.hasPrefix("[Screen: Q3 Report – Total: $4.2M]"))
        #expect(result.contains("The revenue was"))
    }

    @Test func screenContextAbsentWhenNil() {
        let ctx = TextContext(textBeforeCursor: "Hello world", textAfterCursor: "", appName: "Notes", windowTitle: "")
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "", screenContext: nil)
        #expect(!result.contains("[Screen:"))
        #expect(result == "Hello world")
    }

    @Test func screenContextTruncatedAt120Chars() {
        let longScreen = String(repeating: "x", count: 200)
        let ctx = TextContext(textBeforeCursor: "abc", textAfterCursor: "", appName: "Notes", windowTitle: "")
        let result = ContextBuilder.buildPrompt(
            context: ctx, clipboard: nil, history: [], customInstructions: "",
            screenContext: longScreen
        )
        // "[Screen: " (9) + 120 x's + "]" (1) = 130 chars in the hint
        let hintEnd = result.firstIndex(of: "\n") ?? result.endIndex
        let hint = String(result[..<hintEnd])
        #expect(hint == "[Screen: \(String(repeating: "x", count: 120))]")
    }

    @Test func emptyScreenContextBehavesLikeNil() {
        let ctx = TextContext(textBeforeCursor: "Hello", textAfterCursor: "", appName: "Notes", windowTitle: "")
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "", screenContext: "  ")
        #expect(result == "Hello")
        #expect(!result.contains("[Screen:"))
    }

    @Test func screenContextInflatesPromptLengthBeyondTypedText() {
        // This documents the bug that the minimum-prefix guard in AppDependencies must
        // check context.textBeforeCursor, NOT the assembled prompt. When screen context
        // is present, buildPrompt returns "[Screen: ...]<newline><typed>" which can be
        // 130+ chars even when the user has typed only 2 characters.
        let ctx = TextContext(textBeforeCursor: "hi", textAfterCursor: "", appName: "Notes", windowTitle: "")
        let result = ContextBuilder.buildPrompt(
            context: ctx, clipboard: nil, history: [], customInstructions: "",
            screenContext: "A document about quarterly earnings reports and financial projections."
        )
        // Typed text is only 2 chars — well below any reasonable minimum.
        #expect(ctx.textBeforeCursor.count == 2)
        // But the assembled prompt is much longer because of the screen context hint.
        #expect(result.count > 50)
        // And it correctly contains both parts.
        #expect(result.contains("[Screen:"))
        #expect(result.contains("hi"))
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
