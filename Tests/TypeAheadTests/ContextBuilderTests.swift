import Testing
@testable import TypeAhead

@Suite struct ContextBuilderTests {
    @Test func shortContextUsesStandardPrompt() {
        let ctx = TextContext(
            textBeforeCursor: "Hello",
            textAfterCursor: "",
            appName: "Notes",
            windowTitle: "My Note"
        )
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        #expect(!result.contains("<|fim_prefix|>"))
        #expect(result.contains("Hello"))
    }

    @Test func longContextUsesFIMPrompt() {
        let longText = String(repeating: "word ", count: 20)
        let ctx = TextContext(
            textBeforeCursor: longText,
            textAfterCursor: "some text after",
            appName: "Mail",
            windowTitle: "Re: Meeting"
        )
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
        #expect(result.contains("<|fim_prefix|>"))
        #expect(result.contains("<|fim_suffix|>"))
        #expect(result.contains("<|fim_middle|>"))
    }

    @Test func clipboardContextCappedAt400Chars() {
        let longClipboard = String(repeating: "a", count: 600)
        let ctx = TextContext(textBeforeCursor: String(repeating: "word ", count: 20), textAfterCursor: "", appName: "Slack", windowTitle: "")
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: longClipboard, history: [], customInstructions: "")
        let clipboardSectionCount = result.components(separatedBy: String(repeating: "a", count: 401)).count
        #expect(clipboardSectionCount == 1)
    }

    @Test func customInstructionsInjectedFirst() {
        let instructions = "Always write in UK English."
        let ctx = TextContext(textBeforeCursor: String(repeating: "word ", count: 20), textAfterCursor: "", appName: "Notes", windowTitle: "")
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: instructions)
        let instrRange = result.range(of: instructions)
        let fimRange = result.range(of: "<|fim_prefix|>")
        guard let i = instrRange, let f = fimRange else {
            Issue.record("Expected both instruction and FIM markers")
            return
        }
        #expect(i.lowerBound < f.lowerBound)
    }

    @Test func historyExamplesInjectedAsPrefix() {
        let history = ["I think therefore I am", "To be or not to be"]
        let ctx = TextContext(textBeforeCursor: String(repeating: "word ", count: 20), textAfterCursor: "", appName: "Notes", windowTitle: "")
        let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: history, customInstructions: "")
        #expect(result.contains("I think therefore I am"))
        #expect(result.contains("To be or not to be"))
    }
}
