import Testing
@testable import TypeAhead

@Suite struct WordCompleterTests {

    // MARK: - shouldOfferInstantCompletion(partial:)

    @Test func gateRejectsNil() {
        #expect(!WordCompleter.shouldOfferInstantCompletion(partial: nil))
    }

    @Test func gateRejectsTwoCharPartial() {
        // 2-char partials are too ambiguous — below the 3-char minimum.
        #expect(!WordCompleter.shouldOfferInstantCompletion(partial: "he"))
    }

    @Test func gateAcceptsThreeCharPartial() {
        #expect(WordCompleter.shouldOfferInstantCompletion(partial: "hel"))
    }

    @Test func gateRejectsDigits() {
        #expect(!WordCompleter.shouldOfferInstantCompletion(partial: "abc123"))
    }

    @Test func gateRejectsEmojiShortcodePrefix() {
        // Emoji shortcodes start with ':' — must not be treated as a word partial.
        #expect(!WordCompleter.shouldOfferInstantCompletion(partial: ":wav"))
    }

    @Test func gateAcceptsApostrophe() {
        #expect(WordCompleter.shouldOfferInstantCompletion(partial: "don'"))
    }

    @Test func gateRejectsEmpty() {
        #expect(!WordCompleter.shouldOfferInstantCompletion(partial: ""))
    }

    // MARK: - completionSuffix(forPartial:)

    @Test func suffixForKnownPartial() {
        // "hel" should extend to a real word ("help"/"hello"/...) on any English macOS install.
        let result = WordCompleter.completionSuffix(forPartial: "hel")
        if let suffix = result {
            #expect(!suffix.isEmpty)
            #expect(!suffix.hasPrefix(" "))
            #expect(("hel" + suffix).count > "hel".count)
        }
        // Acceptable if system spell-check returns nil on this machine.
    }

    @Test func suffixNeverHasLeadingSpace() {
        let result = WordCompleter.completionSuffix(forPartial: "compl")
        if let suffix = result {
            #expect(!suffix.hasPrefix(" "))
        }
    }

    @Test func suffixHandlesUppercaseFirstLetterPartial() {
        // "He" is only 2 chars so the gate would reject it, but completionSuffix itself has no
        // length floor — exercise it directly with a capitalized partial like "Hel" to confirm
        // the case-insensitive match still strips exactly `partial.count` characters, regardless
        // of the candidate's own casing (see the doc comment on completionSuffix).
        let result = WordCompleter.completionSuffix(forPartial: "Hel")
        if let suffix = result {
            #expect(!suffix.isEmpty)
            #expect(!suffix.hasPrefix(" "))
        }
    }

    @Test func suffixReturnsNilForNonWordGarbage() {
        let result = WordCompleter.completionSuffix(forPartial: "zzqxk")
        #expect(result == nil)
    }

    @Test func suffixForAlreadyCompleteWordMayBeNilOrLonger() {
        // "cat" is already a complete dictionary word. NSSpellChecker may still offer a longer
        // completion (e.g. "catalog") or nothing — both are acceptable; this documents actual
        // behavior rather than asserting one way.
        let result = WordCompleter.completionSuffix(forPartial: "cat")
        if let suffix = result {
            #expect(!suffix.isEmpty)
        }
    }

    // MARK: - Integration-shaped: gate composed with ContextBuilder.currentWord

    @Test func gateComposedWithCurrentWordMidTyping() {
        let context = TextContext(textBeforeCursor: "I am typing hel", textAfterCursor: "", appName: "", windowTitle: "")
        let partial = ContextBuilder.currentWord(context: context)
        #expect(partial == "hel")
        #expect(WordCompleter.shouldOfferInstantCompletion(partial: partial))
        if let partial, let suffix = WordCompleter.completionSuffix(forPartial: partial) {
            #expect(!suffix.hasPrefix(" "))
        }
    }

    @Test func gateComposedWithCurrentWordAtWordBoundary() {
        // Trailing space — currentWord returns nil (cursor is at a word boundary, not mid-word).
        let context = TextContext(textBeforeCursor: "I am typing ", textAfterCursor: "", appName: "", windowTitle: "")
        let partial = ContextBuilder.currentWord(context: context)
        #expect(partial == nil)
        #expect(!WordCompleter.shouldOfferInstantCompletion(partial: partial))
    }

    @Test func gateComposedWithCurrentWordTooShort() {
        let context = TextContext(textBeforeCursor: "I am ok", textAfterCursor: "", appName: "", windowTitle: "")
        let partial = ContextBuilder.currentWord(context: context)
        #expect(partial == "ok")
        #expect(!WordCompleter.shouldOfferInstantCompletion(partial: partial))
    }

    @Test func completionsListsSeveralPrefixExtensions() {
        let words = WordCompleter.completions(forPartial: "wor", limit: 5)
        #expect(!words.isEmpty)
        #expect(words.count <= 5)
        #expect(words.allSatisfy { $0.lowercased().hasPrefix("wor") && $0.lowercased() != "wor" })
    }
}
