import AppKit
import Carbon
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarMenu: StatusBarMenu?
    private let logger = Logger(subsystem: "app.typeahead", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbuffered stdout so print() logs appear immediately when launched via `open`
        // with redirected output (LaunchServices launch → otherwise block-buffered).
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.setActivationPolicy(.accessory)
        let deps = AppDependencies.shared
        statusBarMenu = StatusBarMenu(
            settings: deps.settings,
            pipeline: deps.completionPipeline,
            modelManager: deps.modelManager,
            historyStore: deps.historyStore
        )

        // Keystroke handling with "type-through": if the user types the next character of
        // the current suggestion, advance the ghost and keep it shown (don't regenerate).
        // Only when they diverge do we clear and request a fresh completion.
        deps.keyMonitor.onKeystroke = { [weak deps] event in
            guard let deps else { return }
            // OverlayController resolves type-through vs diverge (OverlayStateMachine.keystroke)
            // and applies the resulting panel/mode/isOverlayVisible mutation; the cursor rect is
            // only actually read (an AX call) when a type-through with remaining text needs it —
            // see the `@autoclosure` on `handleKeystroke`.
            let effect = deps.overlayController.handleKeystroke(
                typedChar: event.characters,
                cursorRect: deps.accessibilityManager.inlineCursorRect()
            )
            switch effect {
            case .advanced:
                return  // typed along with the suggestion — keep it, no regeneration

            case .typedThroughToEmpty(let ghost):
                // The user typed out the entire ghost character-by-character — it disappears
                // because there's nothing left to show, not because it was explicitly accepted
                // (Tab) or rejected (diverging keystroke/Escape).
                deps.recordSuggestionEvent(kind: .typedThrough, ghostText: ghost, metadata: "typedThrough")
                return

            case .cursorUnavailable(let ghost):
                // Cursor position unavailable — the overlay was already hidden rather than left
                // at a stale position. The suggestion is lost mid-type-through through no fault
                // of the user's typing, closer to a rejection than a completed type-through.
                deps.recordSuggestionEvent(kind: .rejected, ghostText: ghost, metadata: "cursorUnavailable")
                return

            case .diverged(let ghost):
                deps.inferenceEngine.cancelCurrent()
                // A ghost was visible and this keystroke wasn't a type-through continuation
                // (handled above) — the suggestion was discarded by a diverging/navigation
                // keystroke. Only record when there was actually something to reject (most
                // keystrokes have no ghost showing at all, and we don't want to flood the event
                // log with no-ops).
                if !ghost.isEmpty {
                    deps.recordSuggestionEvent(kind: .rejected, ghostText: ghost, metadata: "keystrokeDiverged")
                }
            }

            // Navigation and correction keys (backspace, delete, arrows) — only dismiss
            // the overlay; do NOT queue a new suggestion. While the user is correcting text
            // the inference engine would otherwise fight them: every backspace would trigger
            // a new completion that pops up within 200ms. Suggestions resume automatically
            // on the next printable keystroke.
            let correctionKeyCodes: Set<Int> = [
                kVK_Delete, kVK_ForwardDelete,
                kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown
            ]
            if correctionKeyCodes.contains(Int(event.keyCode)) {
                // Also cancel any pending debounce — inferenceEngine.cancelCurrent() only
                // stops active generation; a debounce already queued (e.g. from the
                // diverging character typed just before the backspace) would otherwise
                // fire 180ms later and show a suggestion mid-correction.
                deps.completionPipeline.cancel()
                return
            }

            deps.completionPipeline.keystrokeReceived()
        }

        // Tab — accept the next word, then KEEP the remaining words showing so another Tab
        // accepts the next one. The suggestion persists (no regeneration) until the user
        // types something that diverges from it.
        //
        // Two acceptance modes:
        // • Word-completion (no leading space in ghost): the ghost completes the partial word
        //   the user is currently typing — REPLACE the partial word instead of appending.
        // • New-word (leading space in ghost): append normally with a word separator.
        deps.keyMonitor.onTabPressed = { [weak deps] in
            guard let deps else { return }

            // OverlayController.acceptOutcome resolves the exhaustive Tab verdict
            // (OverlayStateMachine.acceptRequested) and already applies the hide-related side
            // effects for `.passThrough` / `.none` — see its doc comment for why those two both
            // need different `animated` values reproduced from the original guards. What's left
            // here is exactly the AX work each remaining case needs, in the same order as before.
            let outcome = deps.overlayController.acceptOutcome(
                currentEpoch: deps.focusEpoch.epoch,
                tabKeyDisabled: deps.currentPolicy.tabKeyDisabled
            )
            switch outcome {
            case .passThrough:
                // Per-app "Disable Tab accept" (AppPolicyResolver.tabKeyDisabled): the event tap
                // already swallowed this Tab (it only consults isOverlayVisible, see
                // KeyEventMonitor CLAUDE.md notes), so re-inject a literal tab character to
                // preserve the app's own Tab behavior (e.g. indent in a code editor) instead of
                // accepting the suggestion.
                deps.accessibilityManager.injectText("\t")

            case .none:
                // Nothing to do: no ghost was showing, or the acceptance guardrail dropped it
                // because focus drifted since the ghost was generated (never insert a suggestion
                // into a field different from the one it was generated for).
                break

            case .replaceSpell(let ghost, let len):
                let corrected = ghost + " "
                if let element = deps.accessibilityManager.focusedElement() {
                    deps.accessibilityManager.replaceCurrentWord(corrected, wordLength: len, into: element)
                } else {
                    deps.accessibilityManager.injectReplacement(corrected, deletingCount: len)
                }
                // Keep buffer in sync so buffer-fallback mode doesn't re-detect the stale misspelling.
                deps.keyMonitor.keystrokeBuffer.replaceTrailing(count: len, with: corrected)
                deps.overlayController.hide()
                deps.recordSuggestionEvent(kind: .accepted, ghostText: corrected, metadata: "spellCorrection")
                deps.completionPipeline.keystrokeReceived()

            case .replaceEmoji(let ghost, let len):
                if let element = deps.accessibilityManager.focusedElement() {
                    deps.accessibilityManager.replaceCurrentWord(ghost, wordLength: len, into: element)
                } else {
                    // AX element unavailable — backspace the `:shortcode` then inject the emoji.
                    deps.accessibilityManager.injectReplacement(ghost, deletingCount: len)
                }
                // Keep buffer in sync so buffer-fallback mode doesn't re-detect the stale :shortcode.
                deps.keyMonitor.keystrokeBuffer.replaceTrailing(count: len, with: ghost)
                deps.overlayController.hide()
                deps.recordSuggestionEvent(kind: .accepted, ghostText: ghost, metadata: "emoji")
                deps.completionPipeline.keystrokeReceived()

            case .acceptWord(let ghost):
                // Two acceptance modes:
                // • Word-completion (no leading space in ghost): the ghost completes the partial
                //   word the user is currently typing — REPLACE the partial word instead of
                //   appending.
                // • New-word (leading space in ghost): append normally with a word separator.
                let leading = ghost.hasPrefix(" ") ? " " : ""
                let body = leading.isEmpty ? ghost : String(ghost.dropFirst())
                let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let firstWord = parts.first.map(String.init), !firstWord.isEmpty else {
                    deps.overlayController.hide()
                    return
                }

                // In assistant-prefill / FIM mode the model outputs ONLY the suffix tokens
                // that come AFTER the cursor position. The partial word the user is typing
                // (e.g. "Wri") is already in the field; the ghost ("ting") is what follows.
                // Inserting the ghost after the cursor assembles the full word naturally:
                //   "Wri" + insert("ting ") = "Writing "  ✓
                // Replacing the partial would destroy it:
                //   replace("Wri", wordLen=3) with "ting " = "ting "  ✗
                // So we ALWAYS insert — never replace — regardless of isMidWordCompletion.
                let injection = leading + firstWord + " "
                if let element = deps.accessibilityManager.focusedElement() {
                    deps.accessibilityManager.insertCompletion(injection, into: element)
                } else {
                    deps.accessibilityManager.injectText(injection)
                }

                let accepted = firstWord
                deps.keyMonitor.keystrokeBuffer.appendAccepted(accepted + " ")
                let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                Task { @MainActor in try? deps.historyStore.record(accepted: accepted, appName: appName) }
                deps.recordSuggestionEvent(kind: .accepted, ghostText: accepted, metadata: "word")

                // Keep the rest of the suggestion visible for the next Tab. The epoch to keep
                // showing it under is the one the just-accepted ghost was generated at — read
                // back from mode (acceptOutcome left it untouched for the `.acceptWord` case).
                guard case .mlCompletion(_, let generationEpoch) = deps.overlayController.mode else { return }
                let remaining = parts.count > 1 ? String(parts[1]) : ""
                if remaining.isEmpty {
                    // Accepted the last word — hide, then immediately request a fresh suggestion
                    // for the new context so the next Tab has something to accept (rather than
                    // passing through as a literal tab).
                    deps.overlayController.hide()
                    deps.completionPipeline.keystrokeReceived()
                } else {
                    deps.overlayController.continueShowingML(
                        ghost: remaining,
                        epoch: generationEpoch,
                        cursorRect: deps.accessibilityManager.inlineCursorRect()
                    )
                }
            }
        }

        deps.keyMonitor.onDismiss = { [weak deps] in
            guard let deps else { return }
            let ghost = deps.overlayController.mode.ghost
            deps.inferenceEngine.cancelCurrent()
            deps.overlayController.hide(animated: true)  // gentle fade on Escape
            if !ghost.isEmpty {
                deps.recordSuggestionEvent(kind: .dismissed, ghostText: ghost, metadata: "escape")
            }
        }

        // Global ⌃⌥⌘T opens the status menu at the mouse — the always-works entry point when the
        // menu-bar icon is hidden by notch/overflow on a crowded menu bar.
        deps.keyMonitor.onShowMenu = { [weak self] in
            self?.statusBarMenu?.showMenuAtMouse()
        }

        deps.keyMonitor.start()

        // One-time checks. If trusted is false → re-grant in System Settings. If a debugger
        // is attached, cross-process AX reads are DENIED (error -25204) regardless of trust,
        // so ghost text can't find the caret — the app must be launched standalone, not Cmd+R.
        logger.info("Accessibility trusted: \(deps.accessibilityManager.isProcessTrusted, privacy: .public)")
        logger.info("Debugger attached: \(deps.accessibilityManager.isBeingDebugged, privacy: .public) (if true, AX reads will fail — launch the app from Finder, not Xcode Run)")
        // If untrusted, show the system prompt and add the app to the Accessibility list
        // so the user can grant it with one toggle.
        if !deps.accessibilityManager.isProcessTrusted {
            deps.accessibilityManager.promptForTrustIfNeeded()
            logger.info("Not trusted — prompted. Enable TypeAhead in System Settings > Privacy & Security > Accessibility, then relaunch.")
        }

        // Load (and download if needed) the user's chosen model on startup.
        // ModelManager streams progress into its statuses dict, which the UI observes.
        Task { @MainActor in
            let config = ModelConfig.all.first { $0.id == deps.settings.activeModelID }
                ?? ModelConfig.recommended(availableRAMGB: Self.availableRAMGB())
            await deps.modelManager.downloadAndActivate(config: config)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let deps = AppDependencies.shared
        deps.keyMonitor.stop()
        deps.inferenceEngine.unloadModel()
    }

    private static func availableRAMGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
}
