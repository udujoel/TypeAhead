import Foundation

/// What accepting (part of) an ML ghost does to the field: the exact text to insert, the text to
/// record as accepted, and the ghost that stays visible for the next Tab.
///
/// Pure — `AppDelegate`'s Tab (next word) and Shift+Tab (whole suggestion) handlers both build one
/// of these and then do the AX/CGEvent insertion it describes.
struct AcceptPlan: Equatable, Sendable {
    enum Mode: Sendable { case nextWord, all }

    /// Inserted after the cursor, verbatim. In assistant-prefill mode the ghost is only what comes
    /// AFTER the cursor (a mid-word ghost "ting" completes "Wri"), so this is always an insertion,
    /// never a replacement.
    let insertion: String
    /// The accepted words without surrounding whitespace (typing history / telemetry).
    let acceptedText: String
    /// Ghost text still to show after this accept; empty when the whole suggestion was used.
    let remaining: String

    /// - Parameters:
    ///   - ghost: The visible ghost. A leading space means it starts a new word; none means it
    ///     completes the word under the cursor.
    ///   - trailingSpaceAtEnd: Whether a space follows the LAST accepted word (the "Add a space
    ///     after accepted words" setting, B6). A word accepted mid-suggestion is always followed by
    ///     a space, because the remaining ghost has no leading space of its own.
    static func make(ghost: String, mode: Mode, trailingSpaceAtEnd: Bool) -> AcceptPlan? {
        let leading = ghost.hasPrefix(" ") ? " " : ""
        let body = leading.isEmpty ? ghost : String(ghost.dropFirst())
        let endSpace = trailingSpaceAtEnd ? " " : ""

        switch mode {
        case .nextWord:
            let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first.map(String.init), !first.isEmpty else { return nil }
            let remaining = parts.count > 1 ? String(parts[1]) : ""
            let separator = remaining.isEmpty ? endSpace : " "
            return AcceptPlan(insertion: leading + first + separator, acceptedText: first, remaining: remaining)

        case .all:
            let text = body.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return AcceptPlan(insertion: leading + text + endSpace, acceptedText: text, remaining: "")
        }
    }
}
