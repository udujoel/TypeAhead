import Foundation

/// The overlay's current display state — one value everything (Tab handling, keystroke
/// type-through, focus/escape dismissal) is decided from. Replaces the four previously-scattered
/// pieces of state (`AppDependencies.spellCorrectionLength`, `emojiReplacementLength`,
/// `suggestionEpoch`, and the "is anything showing" check on `CompletionOverlay.currentText`)
/// with one source of truth (WS3).
///
/// `KeyEventMonitor.isOverlayVisible` still exists separately as a derived mirror the CGEventTap's
/// C callback can read synchronously — CLAUDE.md forbids doing AX/heavy work inside that callback,
/// so it needs a plain stored `Bool` it can read without hopping through `OverlayController`.
/// `OverlayController` keeps that mirror in sync every time `mode` changes; nothing else should
/// write `isOverlayVisible` directly once WS3 lands.
enum OverlayMode: Equatable {
    case hidden
    /// ML-generated ghost text. `epoch` is the `FocusEpoch.epoch` value at generation time; Tab
    /// acceptance is refused once focus has moved past it (see `FocusEpoch`).
    case mlCompletion(ghost: String, epoch: Int)
    /// Spell-correction suggestion (`TypoDetector`). `replaceLen` is the character count of the
    /// misspelled word Tab must delete before inserting `ghost`.
    case spellCorrection(ghost: String, replaceLen: Int, epoch: Int)
    /// Emoji suggestion for a `:shortcode` (`EmojiSuggester`). `replaceLen` is 1 (colon) +
    /// shortcode length — the characters Tab must delete before inserting `ghost`.
    case emoji(ghost: String, replaceLen: Int, epoch: Int)

    /// The ghost text this mode is showing (empty when hidden).
    var ghost: String {
        switch self {
        case .hidden: return ""
        case .mlCompletion(let ghost, _), .spellCorrection(let ghost, _, _), .emoji(let ghost, _, _):
            return ghost
        }
    }

    var isVisible: Bool { self != .hidden }
}

/// Outcome of a keystroke arriving while the overlay was (or wasn't) showing something.
enum OverlayKeystrokeOutcome: Equatable {
    /// Type-through: the typed character matched the ghost's next character and more of the
    /// ghost remains. Caller should repaint with the new mode's ghost text (no regeneration).
    case advanced(newMode: OverlayMode)
    /// The user typed out the entire ghost character-by-character — nothing left to show. Not a
    /// rejection (nothing was discarded) and not an acceptance (no Tab/AX insertion happened).
    case typedThroughToEmpty
    /// The keystroke diverged from the ghost (or there was no ghost, or the mode never
    /// type-throughs at all) — hide unconditionally. Caller records a "keystrokeDiverged"
    /// rejection event only if a ghost had actually been visible.
    case diverged
}

/// Outcome of a Tab press (`acceptRequested`).
enum OverlayAcceptOutcome: Equatable {
    /// Insert the next word of an ML completion. The caller (glue code) still does the
    /// word-vs-remaining split and AX insertion — this only says "yes, accept the ML ghost."
    case acceptWord(ghost: String)
    /// Replace the misspelled word (`replaceLen` chars) with the spell-correction ghost.
    case replaceSpell(ghost: String, replaceLen: Int)
    /// Replace the `:shortcode` (`replaceLen` chars) with the emoji ghost.
    case replaceEmoji(ghost: String, replaceLen: Int)
    /// Tab-accept is disabled for this app (`AppPolicyResolver.tabKeyDisabled`) — inject a
    /// literal tab character instead of accepting anything.
    case passThrough
    /// Nothing to do: no ghost showing, or the suggestion's epoch is stale (focus moved to a
    /// different field/app since it was generated — see `FocusEpoch`).
    case none
}

/// Pure transition functions over `OverlayMode`. No AppKit/AX/SwiftData — this only decides WHAT
/// should happen; `OverlayController` mutates the panel + `KeyEventMonitor.isOverlayVisible`
/// mirror, and `AppDelegate`'s closures (via adapters) do the actual AX injection.
enum OverlayStateMachine {

    // MARK: - Show

    static func showML(ghost: String, epoch: Int) -> OverlayMode {
        .mlCompletion(ghost: ghost, epoch: epoch)
    }

    static func showSpell(ghost: String, replaceLen: Int, epoch: Int) -> OverlayMode {
        .spellCorrection(ghost: ghost, replaceLen: replaceLen, epoch: epoch)
    }

    static func showEmoji(ghost: String, replaceLen: Int, epoch: Int) -> OverlayMode {
        .emoji(ghost: ghost, replaceLen: replaceLen, epoch: epoch)
    }

    // MARK: - Keystroke (type-through vs diverge)

    /// A keystroke arrived while `mode` was current. `typedChar` is the single printable
    /// character the user typed, or `nil` for anything that isn't a plain length-1 insertion
    /// (arrows, backspace, multi-char/IME input, modified keys) — those always diverge here;
    /// routing them to "cancel only, don't re-fire the pipeline" (correction keys) is an
    /// app-policy decision made by the caller, not part of overlay state.
    ///
    /// Mirrors `AppDelegate.onKeystroke` exactly: spell corrections never type-through — a
    /// spell correction is a *replacement*, not an insertion, so advancing the displayed ghost
    /// would desync it from `replaceLen` and corrupt the eventual Tab replacement. ML and emoji
    /// ghosts both type-through (the original code gates only on `spellCorrectionLength == 0`,
    /// which is true for both).
    static func keystroke(mode: OverlayMode, typedChar: String?) -> OverlayKeystrokeOutcome {
        switch mode {
        case .hidden:
            return .diverged
        case .spellCorrection:
            return .diverged
        case .mlCompletion(let ghost, let epoch):
            return typeThroughOutcome(ghost: ghost, typedChar: typedChar) { remaining in
                .mlCompletion(ghost: remaining, epoch: epoch)
            }
        case .emoji(let ghost, let replaceLen, let epoch):
            return typeThroughOutcome(ghost: ghost, typedChar: typedChar) { remaining in
                .emoji(ghost: remaining, replaceLen: replaceLen, epoch: epoch)
            }
        }
    }

    private static func typeThroughOutcome(
        ghost: String,
        typedChar: String?,
        wrap: (String) -> OverlayMode
    ) -> OverlayKeystrokeOutcome {
        guard !ghost.isEmpty, let typed = typedChar, typed.count == 1 else {
            return .diverged
        }
        // Exact match is the common case (typed char literally equals the ghost's next
        // character). WP-2 divergence-persistence design decision: also treat two DIFFERENT
        // word-boundary characters (space/newline) as a match — e.g. the ghost starts with " "
        // but the user pressed Return instead — since that's really a type-through with
        // different spacing/line-break choice, not a genuine divergence from what the model
        // predicted. Every other mismatch still diverges unconditionally: a wrong ghost must
        // never stay on screen (Tab must never be able to accept text the user didn't actually
        // type towards).
        guard ghost.hasPrefix(typed) || isBoundaryEquivalent(ghostHead: ghost.first, typed: typed) else {
            return .diverged
        }
        let remaining = String(ghost.dropFirst())
        if remaining.isEmpty { return .typedThroughToEmpty }
        return .advanced(newMode: wrap(remaining))
    }

    /// True when `ghostHead` and the single-character `typed` are both "word boundary"
    /// characters (space or newline) — see `typeThroughOutcome`'s doc comment.
    private static func isBoundaryEquivalent(ghostHead: Character?, typed: String) -> Bool {
        guard let ghostHead, let typedHead = typed.first, typed.count == 1 else { return false }
        return isWordBoundary(ghostHead) && isWordBoundary(typedHead)
    }

    private static func isWordBoundary(_ char: Character) -> Bool {
        char == " " || char == "\n"
    }

    // MARK: - Escape / focus change

    /// Escape and focus-change both hide unconditionally, regardless of mode.
    static func hide() -> OverlayMode { .hidden }

    // MARK: - Tab accept

    /// `tabKeyDisabled` (from `AppPolicyResolver`) is an app-policy fact, not overlay state, but
    /// the real Tab handler checks it before anything else — encoded here too so the whole
    /// exhaustive-outcome switch lives in one place.
    static func acceptRequested(mode: OverlayMode, currentEpoch: Int, tabKeyDisabled: Bool) -> OverlayAcceptOutcome {
        if tabKeyDisabled { return .passThrough }
        switch mode {
        case .hidden:
            return .none
        case .mlCompletion(let ghost, let epoch):
            guard epoch == currentEpoch else { return .none }
            return .acceptWord(ghost: ghost)
        case .spellCorrection(let ghost, let replaceLen, let epoch):
            guard epoch == currentEpoch else { return .none }
            return .replaceSpell(ghost: ghost, replaceLen: replaceLen)
        case .emoji(let ghost, let replaceLen, let epoch):
            guard epoch == currentEpoch else { return .none }
            return .replaceEmoji(ghost: ghost, replaceLen: replaceLen)
        }
    }
}
