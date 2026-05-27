import Foundation

enum EmojiSuggester {
    private static let catalog: [(shortcode: String, emoji: String)] = [
        ("wave", "👋"), ("fire", "🔥"), ("heart", "❤️"),
        ("thumbsup", "👍"), ("smile", "😊"), ("laugh", "😂"),
        ("cry", "😢"), ("tada", "🎉"), ("rocket", "🚀"),
        ("star", "⭐"), ("check", "✅"), ("x", "❌"),
        ("warning", "⚠️"), ("bulb", "💡"), ("clap", "👏"),
        ("pray", "🙏"), ("eyes", "👀"), ("muscle", "💪"),
        ("ok", "👌"),
    ]

    static func isEmojiMode(textBeforeCursor: String) -> Bool {
        guard let lastColon = textBeforeCursor.lastIndex(of: ":") else { return false }
        let afterColon = String(textBeforeCursor[textBeforeCursor.index(after: lastColon)...])
        return !afterColon.contains(" ") && !afterColon.isEmpty
    }

    static func shortcode(from textBeforeCursor: String) -> String? {
        guard let lastColon = textBeforeCursor.lastIndex(of: ":") else { return nil }
        let after = String(textBeforeCursor[textBeforeCursor.index(after: lastColon)...])
        return after.isEmpty ? nil : after
    }

    static func suggest(shortcode: String) -> [String] {
        catalog
            .filter { $0.shortcode.hasPrefix(shortcode.lowercased()) }
            .map(\.emoji)
    }
}
