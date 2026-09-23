import Foundation

/// B2 (Cotypist parity): after Escape dismisses a ghost, suggestions pause briefly so the very
/// next keystroke doesn't pop a fresh suggestion for the word the user just rejected.
///
/// The pause ends at whichever comes first:
/// - the user types a word boundary (space, newline, tab, or `.,!?;:`) — they've moved on to a
///   new word, where a suggestion is welcome again;
/// - `maxDuration` elapses — a safety cap so a stray Escape never silences TypeAhead for long.
///
/// Pure value type; `AppDelegate` feeds it keystrokes and `AppDependencies.runCompletion` asks
/// `isActive` before doing any work.
struct DismissCooldown: Sendable, Equatable {
    let startedAt: Date
    let maxDuration: TimeInterval
    private(set) var reachedWordBoundary = false

    init(now: Date, maxDuration: TimeInterval = 10) {
        self.startedAt = now
        self.maxDuration = maxDuration
    }

    /// Feed every keystroke's characters (as `NSEvent.characters` reports them) here.
    mutating func keystroke(_ characters: String?) {
        guard let characters, !characters.isEmpty else { return }
        if characters.unicodeScalars.contains(where: Self.isBoundary) {
            reachedWordBoundary = true
        }
    }

    func isActive(now: Date) -> Bool {
        !reachedWordBoundary && now.timeIntervalSince(startedAt) < maxDuration
    }

    private static func isBoundary(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || ".,!?;:".unicodeScalars.contains(scalar)
    }
}
