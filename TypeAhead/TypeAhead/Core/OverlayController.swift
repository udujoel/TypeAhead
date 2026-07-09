import AppKit

/// Effect of routing a keystroke through the overlay. Callers (currently just `AppDelegate`'s
/// `onKeystroke` closure) branch on this instead of re-deriving type-through/diverge logic
/// themselves.
enum OverlayKeystrokeEffect: Equatable {
    /// Ghost advanced in place (type-through) — still showing, nothing to record.
    case advanced
    /// The user typed out the entire ghost — nothing left to show. Caller should record a
    /// `.typedThrough` event with `previousGhost` if it wants telemetry (matches the original
    /// "typed the whole thing character-by-character" case).
    case typedThroughToEmpty(previousGhost: String)
    /// A type-through was in progress (ghost had more characters) but the caret rect couldn't be
    /// read, so the overlay was hidden rather than left stale. Caller should record a
    /// `.rejected` / `"cursorUnavailable"` event.
    case cursorUnavailable(previousGhost: String)
    /// The keystroke didn't continue the ghost (or nothing was showing) — overlay is now hidden.
    /// Caller should cancel in-flight inference and, if `previousGhost` is non-empty, record a
    /// `.rejected` / `"keystrokeDiverged"` event.
    case diverged(previousGhost: String)
}

/// Owns the overlay's `OverlayMode`, the on-screen `CompletionOverlay` panel, and the
/// `KeyEventMonitor.isOverlayVisible` mirror the CGEventTap callback reads synchronously.
///
/// Before WS3 these three things (a scattered set of vars on `AppDependencies`, the panel's own
/// `currentText`, and the tap's `isOverlayVisible` flag) had to be kept in sync by hand across
/// four call sites — the recurring source of Tab-doubling-class bugs. This type is now the only
/// thing allowed to touch `panel` or `keyMonitor.isOverlayVisible`; every other caller goes
/// through one of the methods below, so `mode` can never drift from what's actually on screen.
///
/// CLAUDE.md rule preserved: the CGEventTap's C callback still reads `keyMonitor.isOverlayVisible`
/// directly as a plain stored `Bool` (no hop through this class, no AX/heavy work in the
/// callback) — this class just makes sure that Bool is always an accurate mirror of `mode`.
@MainActor
final class OverlayController {
    private let panel: CompletionOverlay
    private let keyMonitor: KeyEventMonitor
    /// Fire-and-forget telemetry hook for a suppressed placement (WS5). Injected rather than
    /// reaching for `AppDependencies.shared` directly: `AppDependencies.swift` requires Sparkle
    /// and is excluded from the SPM test target, but this file (`OverlayController.swift`) is
    /// NOT excluded — it needs to stay linkable/testable without that dependency. `AppDependencies`
    /// wires this to its own `recordSuggestionEvent` when constructing `overlayController`.
    private let onPlacementSuppressed: () -> Void

    private(set) var mode: OverlayMode = .hidden

    init(panel: CompletionOverlay, keyMonitor: KeyEventMonitor, onPlacementSuppressed: @escaping () -> Void = {}) {
        self.panel = panel
        self.keyMonitor = keyMonitor
        self.onPlacementSuppressed = onPlacementSuppressed
    }

    // MARK: - Show (fast paths + ML)

    /// Spell-correction fast path. Always a fresh "shown" — the spell fast path re-detects from
    /// scratch every cycle, it never streams/updates in place.
    ///
    /// `presentation` (WS5 — `PlacementPolicy.presentation(for:)`) gates whether this actually
    /// paints: `.suppress` means the placement guess (mouse position) is untrustworthy enough
    /// that showing the ghost anywhere would read as "buggy app," so we no-op and record a
    /// rejected/`placementSuppressed` event instead. `.inline` and `.pinnedBar` both paint at
    /// `cursorRect` as before — for `.pinnedBar` that rect is already the pinned-bar origin
    /// (`OverlayPositioner.pinnedOrigin`, computed upstream in `AccessibilityManager`), so no
    /// separate rendering path is needed to "keep that look."
    func showSpell(ghost: String, replaceLen: Int, epoch: Int, cursorRect: NSRect, fontSize: CGFloat, presentation: PlacementPresentation) {
        guard presentation != .suppress else {
            recordSuppressed()
            return
        }
        mode = OverlayStateMachine.showSpell(ghost: ghost, replaceLen: replaceLen, epoch: epoch)
        panel.show(text: ghost, near: cursorRect, fontSize: fontSize)
        keyMonitor.isOverlayVisible = true
    }

    /// Emoji fast path. Same shape as `showSpell` — always a fresh "shown". See `showSpell` for
    /// the `presentation` gating.
    func showEmoji(ghost: String, replaceLen: Int, epoch: Int, cursorRect: NSRect, fontSize: CGFloat, presentation: PlacementPresentation) {
        guard presentation != .suppress else {
            recordSuppressed()
            return
        }
        mode = OverlayStateMachine.showEmoji(ghost: ghost, replaceLen: replaceLen, epoch: epoch)
        panel.show(text: ghost, near: cursorRect, fontSize: fontSize)
        keyMonitor.isOverlayVisible = true
    }

    /// ML completion. Streaming tokens call this repeatedly for one generation cycle: if the
    /// overlay is already showing something (from earlier in this same cycle), update the panel
    /// in place instead of re-showing — re-showing would re-trigger "shown" telemetry for every
    /// streamed token. Returns `true` only on the first paint of a cycle, so the caller knows
    /// whether to record a `.shown` event (mirrors the original
    /// `isOverlayVisible && !currentText.isEmpty` check in `AppDependencies.runCompletion`).
    ///
    /// See `showSpell` for the `presentation` gating (`.suppress` no-ops and records
    /// `placementSuppressed` instead of painting).
    @discardableResult
    func showOrUpdateML(ghost: String, epoch: Int, cursorRect: NSRect, fontSize: CGFloat, presentation: PlacementPresentation) -> Bool {
        guard presentation != .suppress else {
            recordSuppressed()
            return false
        }
        if mode.isVisible {
            mode = OverlayStateMachine.showML(ghost: ghost, epoch: epoch)
            panel.update(text: ghost, near: cursorRect)
            return false
        } else {
            mode = OverlayStateMachine.showML(ghost: ghost, epoch: epoch)
            panel.show(text: ghost, near: cursorRect, fontSize: fontSize)
            keyMonitor.isOverlayVisible = true
            return true
        }
    }

    /// Fire-and-forget telemetry for a suppressed placement (WS5) — see `onPlacementSuppressed`.
    private func recordSuppressed() {
        onPlacementSuppressed()
    }

    /// After a word is accepted from an ML completion and the caller (glue code — the
    /// word-vs-remaining split stays there, see `AppDelegate`) computes what's left, keep showing
    /// it for the next Tab. If `cursorRect` is nil, this is a silent no-op — the overlay is left
    /// showing its previous (now stale) text. That mirrors a pre-existing edge case in the
    /// original code (the `else if let rect = ...` had no `else` branch); preserved rather than
    /// "fixed" per the behavior-preserving mandate.
    func continueShowingML(ghost: String, epoch: Int, cursorRect: NSRect?) {
        guard let cursorRect else { return }
        mode = OverlayStateMachine.showML(ghost: ghost, epoch: epoch)
        panel.update(text: ghost, near: cursorRect)
        keyMonitor.isOverlayVisible = true
    }

    // MARK: - Keystroke

    /// Routes a keystroke through `OverlayStateMachine.keystroke` and applies the panel/mode/
    /// mirror side effects. `cursorRect` is `@autoclosure` so the caret rect is only read (an AX
    /// call) when actually needed — the original code only fetched it inside the
    /// advance-with-nonempty-remainder branch.
    func handleKeystroke(typedChar: String?, cursorRect: @autoclosure () -> NSRect?) -> OverlayKeystrokeEffect {
        let previousGhost = mode.ghost
        let outcome = OverlayStateMachine.keystroke(mode: mode, typedChar: typedChar)
        switch outcome {
        case .advanced(let newMode):
            guard let rect = cursorRect() else {
                mode = .hidden
                keyMonitor.isOverlayVisible = false
                panel.hide(animated: false)
                return .cursorUnavailable(previousGhost: previousGhost)
            }
            mode = newMode
            panel.update(text: newMode.ghost, near: rect)
            return .advanced
        case .typedThroughToEmpty:
            mode = .hidden
            keyMonitor.isOverlayVisible = false
            panel.hide(animated: false)
            return .typedThroughToEmpty(previousGhost: previousGhost)
        case .diverged:
            mode = .hidden
            keyMonitor.isOverlayVisible = false
            panel.hide(animated: false)
            return .diverged(previousGhost: previousGhost)
        }
    }

    // MARK: - Escape / focus change / generic hide

    /// Hides unconditionally. `animated` is forwarded to `CompletionOverlay.hide` verbatim —
    /// call sites intentionally differ (instant hide on keystroke/focus-change to avoid flicker,
    /// gentle fade on Escape) and that distinction is preserved by passing it explicitly rather
    /// than hardcoding it here.
    func hide(animated: Bool = true) {
        mode = .hidden
        keyMonitor.isOverlayVisible = false
        panel.hide(animated: animated)
    }

    // MARK: - Tab accept

    /// Resolves what Tab should do and applies the hide-related side effects for the outcomes
    /// that don't need further AX work from the caller (`.passThrough`, `.none`). The `.none`
    /// case covers two distinct original guards with different `animated` defaults — "nothing
    /// was showing" (`completionOverlay.hide()`, animated defaults to true) vs. "epoch went
    /// stale" (`completionOverlay.hide(animated: false)`) — reproduced exactly by checking `mode`
    /// before it's cleared. `.acceptWord` / `.replaceSpell` / `.replaceEmoji` are left entirely to
    /// the caller: they do the AX insertion/replacement and then call `hide()` or
    /// `continueShowingML` themselves once that work succeeds, matching the original ordering
    /// (mode stays untouched here for those three cases).
    func acceptOutcome(currentEpoch: Int, tabKeyDisabled: Bool) -> OverlayAcceptOutcome {
        let wasHidden = mode == .hidden
        let outcome = OverlayStateMachine.acceptRequested(mode: mode, currentEpoch: currentEpoch, tabKeyDisabled: tabKeyDisabled)
        switch outcome {
        case .passThrough:
            hide(animated: false)
        case .none:
            hide(animated: wasHidden)
        case .acceptWord, .replaceSpell, .replaceEmoji:
            break
        }
        return outcome
    }
}
