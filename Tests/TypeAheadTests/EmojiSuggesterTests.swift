import Testing
@testable import TypeAhead

@Suite struct EmojiSuggesterTests {
    @Test func detectsColonTrigger() {
        #expect(EmojiSuggester.isEmojiMode(textBeforeCursor: "Hello :wav") == true)
        #expect(EmojiSuggester.isEmojiMode(textBeforeCursor: "Hello world") == false)
    }

    @Test func extractsShortcode() {
        let code = EmojiSuggester.shortcode(from: "Hello :wave")
        #expect(code == "wave")
    }

    @Test func findsMatchingEmoji() {
        let results = EmojiSuggester.suggest(shortcode: "wave")
        #expect(results.contains("👋"))
    }

    @Test func returnsEmptyForNoMatch() {
        let results = EmojiSuggester.suggest(shortcode: "zzznomatch")
        #expect(results.isEmpty)
    }
}
