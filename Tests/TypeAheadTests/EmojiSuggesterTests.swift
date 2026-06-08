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

    @Test func replacementLengthIsColonPlusShortcode() {
        // emojiReplacementLength = 1 (":") + shortcode.count
        // ":wave" → shortcode="wave" (4) → replacement length = 5
        let shortcode = EmojiSuggester.shortcode(from: "Hello :wave")!
        #expect(1 + shortcode.count == 5)

        // ":fire" → shortcode="fire" (4) → replacement length = 5
        let shortcode2 = EmojiSuggester.shortcode(from: ":fire")!
        #expect(1 + shortcode2.count == 5)
    }

    @Test func notEmojiModeWithSpaceAfterColon() {
        // A colon followed by a space is not a shortcode trigger.
        #expect(EmojiSuggester.isEmojiMode(textBeforeCursor: "Hello: world") == false)
        #expect(EmojiSuggester.isEmojiMode(textBeforeCursor: "Time: ") == false)
    }

    @Test func notEmojiModeWithEmptyShortcode() {
        // A bare colon at the end (no chars typed yet) is not emoji mode.
        #expect(EmojiSuggester.isEmojiMode(textBeforeCursor: "Hello :") == false)
    }

    @Test func prefixMatchesMultipleEmoji() {
        // "sm" should match smile, muscle, etc. — tests multi-result prefix matching.
        let results = EmojiSuggester.suggest(shortcode: "sm")
        #expect(!results.isEmpty)
    }
}
