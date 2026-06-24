import Foundation

/// Tracks "focus epochs" — a counter that bumps every time the user moves to a different text
/// field or app. It exists to stop two off-topic failures:
///
/// 1. **Stale context.** When focus changes, callers reset the keystroke buffer / cancel
///    inference so the next suggestion is built only from the *new* field.
/// 2. **Wrong-field insertion.** A suggestion generated in epoch N must never be inserted after
///    focus has moved on. Callers stamp each shown suggestion with the current `epoch` and check
///    `mayAccept(stampedEpoch:)` before writing — a mismatch means focus drifted, so the accept
///    is dropped.
///
/// This type is pure (no AppKit/AX I/O) so it is unit-testable under `swift test`. The actual
/// focus-change *detection* — `NSWorkspace` app-activation and `CFEqual` element comparison —
/// lives in the app layer and simply calls `focusChanged()`.
@MainActor
final class FocusEpoch {
    private(set) var epoch: Int = 0

    /// Record that focus moved to a different field/app. Suggestions stamped with an earlier
    /// epoch are no longer acceptable.
    func focusChanged() {
        epoch &+= 1
    }

    /// Whether a suggestion stamped at `stampedEpoch` may still be accepted: only when focus has
    /// not changed since it was generated.
    func mayAccept(stampedEpoch: Int) -> Bool {
        stampedEpoch == epoch
    }
}
