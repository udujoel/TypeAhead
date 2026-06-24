import Testing
@testable import TypeAhead

@Suite struct AppInsertionPolicyTests {

    // MARK: - CGEvent apps

    @Test func chromeBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.google.Chrome") == .cgEvent)
    }

    @Test func chromeCanaryVariantUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.google.Chrome.canary") == .cgEvent)
    }

    @Test func edgeBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.microsoft.edgemac") == .cgEvent)
    }

    @Test func edgeCanaryVariantUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.microsoft.edgemac.Canary") == .cgEvent)
    }

    @Test func firefoxBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "org.mozilla.firefox") == .cgEvent)
    }

    @Test func firefoxNightlyVariantUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "org.mozilla.firefoxNightly") == .cgEvent)
    }

    @Test func safariBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.apple.Safari") == .cgEvent)
    }

    @Test func slackBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.tinyspeck.slackmacgap") == .cgEvent)
    }

    @Test func discordBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.hnc.Discord") == .cgEvent)
    }

    @Test func obsidianBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "md.obsidian") == .cgEvent)
    }

    @Test func notionBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "notion.id") == .cgEvent)
    }

    @Test func cursorBundleIDUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "io.cursor.Cursor") == .cgEvent)
    }

    @Test func claudeDesktopUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.anthropic.claudefordesktop") == .cgEvent)
    }

    @Test func teamsUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.microsoft.teams2") == .cgEvent)
    }

    @Test func vscodeUsesCGEvent() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.microsoft.VSCode") == .cgEvent)
    }

    // MARK: - AX apps (native AppKit/SwiftUI)

    @Test func textEditBundleIDUsesAX() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.apple.TextEdit") == .ax)
    }

    @Test func notesBundleIDUsesAX() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.apple.Notes") == .ax)
    }

    @Test func mailBundleIDUsesAX() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.apple.mail") == .ax)
    }

    @Test func emptyBundleIDDefaultsToAX() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "") == .ax)
    }

    @Test func unknownBundleIDDefaultsToAX() {
        #expect(AppInsertionPolicy.preferredMethod(forBundleID: "com.example.UnknownApp") == .ax)
    }

    // MARK: - Unreliable caret bounds (Electron/Chromium)

    @Test func teamsHasUnreliableCaretBounds() {
        #expect(AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.microsoft.teams2"))
    }

    @Test func claudeDesktopHasUnreliableCaretBounds() {
        #expect(AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.anthropic.claudefordesktop"))
    }

    @Test func slackHasUnreliableCaretBounds() {
        #expect(AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.tinyspeck.slackmacgap"))
    }

    @Test func textEditHasReliableCaretBounds() {
        #expect(!AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.apple.TextEdit"))
    }

    @Test func emptyBundleIDHasReliableCaretBounds() {
        #expect(!AppInsertionPolicy.unreliableCaretBounds(forBundleID: ""))
    }
}
