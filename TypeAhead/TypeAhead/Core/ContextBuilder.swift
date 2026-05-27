import Foundation

struct TextContext: Sendable {
    let textBeforeCursor: String
    let textAfterCursor: String
    let appName: String
    let windowTitle: String
}

enum ContextBuilder {
    private static let maxPrefixChars    = 200  // smaller = faster first token on small models
    private static let maxSuffixChars    = 60
    private static let maxHistoryItems   = 2
    private static let maxClipboardChars = 200

    /// Builds a concise prompt for an instruction-following model.
    /// The system prompt in `InferenceEngine` defines the task; this supplies raw context only.
    static func buildPrompt(
        context: TextContext,
        clipboard: String?,
        history: [String],
        customInstructions: String
    ) -> String {
        var parts: [String] = []

        // App + window helps the model match register (Slack vs Terminal vs Pages)
        if !context.appName.isEmpty {
            var appLine = "[\(context.appName)"
            if !context.windowTitle.isEmpty { appLine += " — \(context.windowTitle)" }
            appLine += "]"
            parts.append(appLine)
        }

        if !customInstructions.isEmpty {
            parts.append("[\(customInstructions)]")
        }

        let recent = Array(history.prefix(maxHistoryItems))
        if !recent.isEmpty {
            parts.append("[style: \(recent.joined(separator: " | "))]")
        }

        if let clip = clipboard, clip.count > 10 {
            parts.append("[context: \(String(clip.prefix(maxClipboardChars)))]")
        }

        // The text to complete — this is the primary signal for the model
        let prefix = String(context.textBeforeCursor.suffix(maxPrefixChars))
        parts.append(prefix)

        // Suffix hint helps the model bridge the completion to what follows
        if !context.textAfterCursor.isEmpty {
            let suffix = String(context.textAfterCursor.prefix(maxSuffixChars))
            parts.append("<CURSOR>\(suffix)")
        }

        return parts.joined(separator: "\n")
    }
}
