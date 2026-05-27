import Foundation

struct TextContext: Sendable {
    let textBeforeCursor: String
    let textAfterCursor: String
    let appName: String
    let windowTitle: String
}

enum ContextBuilder {
    private static let fimThresholdChars = 50
    private static let maxClipboardChars = 400
    private static let maxSuffixChars = 100
    private static let maxPrefixChars = 200

    static func buildPrompt(
        context: TextContext,
        clipboard: String?,
        history: [String],
        customInstructions: String
    ) -> String {
        var parts: [String] = []

        if !customInstructions.isEmpty {
            parts.append(customInstructions)
        }

        if !history.isEmpty {
            parts.append("Examples of your writing style:")
            parts.append(contentsOf: history.prefix(5))
        }

        let appContext = "App: \(context.appName)\(context.windowTitle.isEmpty ? "" : " — \(context.windowTitle)")"
        parts.append(appContext)

        if let clip = clipboard, !clip.isEmpty {
            let trimmed = String(clip.prefix(maxClipboardChars))
            parts.append("Clipboard context: \(trimmed)")
        }

        let prefix = String(context.textBeforeCursor.suffix(maxPrefixChars))
        let suffix = String(context.textAfterCursor.prefix(maxSuffixChars))

        if context.textBeforeCursor.count >= fimThresholdChars {
            let header = parts.joined(separator: "\n")
            return "<|fim_prefix|>\(header)\n\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>"
        } else {
            parts.append(prefix)
            return parts.joined(separator: "\n")
        }
    }
}
