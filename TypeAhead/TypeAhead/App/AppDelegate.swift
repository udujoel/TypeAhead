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
            deps.dismissCooldown?.keystroke(event.characters)
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
        // types something that diverges from it. Shift+Tab (A7) accepts the whole suggestion.
        deps.keyMonitor.onTabPressed = { [weak deps] in
            deps.map { Self.accept(.nextWord, deps: $0) }
        }
        deps.keyMonitor.onShiftTabPressed = { [weak deps] in
            deps.map { Self.accept(.all, deps: $0) }
        }

        // ⌥Tab (B1) — the key monitor already let a plain Tab through to the app; drop the ghost
        // it would otherwise have accepted.
        deps.keyMonitor.onTabPassthrough = { [weak deps] in
            guard let deps else { return }
            let ghost = deps.overlayController.mode.ghost
            deps.inferenceEngine.cancelCurrent()
            deps.overlayController.hide(animated: false)
            if !ghost.isEmpty {
                deps.recordSuggestionEvent(kind: .dismissed, ghostText: ghost, metadata: "optionTab")
            }
        }

        deps.keyMonitor.onDismiss = { [weak deps] in
            guard let deps else { return }
            let ghost = deps.overlayController.mode.ghost
            deps.inferenceEngine.cancelCurrent()
            deps.overlayController.hide(animated: true)  // gentle fade on Escape
            if !ghost.isEmpty {
                deps.recordSuggestionEvent(kind: .dismissed, ghostText: ghost, metadata: "escape")
                // B2: rejecting a suggestion with Escape also pauses suggestions until the next
                // word (or a short cap), so the next keystroke doesn't pop a replacement.
                deps.dismissCooldown = DismissCooldown(now: Date())
                deps.completionPipeline.cancel()
            }
        }

        // Global ⌃⌥⌘T opens the status menu at the mouse — the always-works entry point when the
        // menu-bar icon is hidden by notch/overflow on a crowded menu bar.
        deps.keyMonitor.onShowMenu = { [weak self] in
            self?.statusBarMenu?.showMenuAtMouse()
        }

        // Global ⌃⌥⌘` (B3) — flip completions for the frontmost app, same as the status menu's
        // per-app item.
        deps.keyMonitor.onToggleCurrentApp = { [weak self] in
            self?.statusBarMenu?.toggleFrontmostApp()
        }

        // Word alternatives: ⌥↓ lists them, 1–3 inserts one, any other key closes the list.
        deps.keyMonitor.canRequestAlternatives = { [weak deps] in deps?.canRequestWordAlternatives() ?? false }
        deps.keyMonitor.onAlternativesRequested = { [weak deps] in
            // Nothing to offer after all — give the swallowed ⌥↓ back to the app.
            if deps?.requestWordAlternatives() == false {
                deps?.accessibilityManager.injectKey(CGKeyCode(kVK_DownArrow), flags: .maskAlternate)
            }
        }
        deps.keyMonitor.onAlternativeChosen = { [weak deps] index in deps?.chooseWordAlternative(at: index) }
        deps.keyMonitor.onAlternativesClosed = { [weak deps] in deps?.closeWordAlternatives() }

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

        // Always open the Settings window on launch. The menu-bar status item can be hidden
        // by the notch / menu-bar overflow on crowded setups (its window attaches fine but
        // macOS gives it no visible slot), leaving no discoverable way into the app — the
        // window guarantees reachability. The user closes it like any normal window; the
        // app keeps running as a menu-bar accessory.
        SettingsWindowController.shared.open()
    }

    /// Tab (`.nextWord`) and Shift+Tab (`.all`) acceptance. `OverlayController.acceptOutcome`
    /// resolves the exhaustive verdict (OverlayStateMachine.acceptRequested) and already applies
    /// the hide side effects for `.passThrough` / `.none`; each remaining case does its AX work.
    @MainActor
    private static func accept(_ mode: AcceptPlan.Mode, deps: AppDependencies) {
        let outcome = deps.overlayController.acceptOutcome(
            currentEpoch: deps.focusEpoch.epoch,
            tabKeyDisabled: deps.currentPolicy.tabKeyDisabled
        )
        switch outcome {
        case .passThrough:
            // Per-app "Disable Tab accept" (AppPolicyResolver.tabKeyDisabled): the event tap
            // already swallowed this key (it only consults isOverlayVisible), so re-post a real
            // Tab / Shift+Tab to preserve the app's own behavior (indent, next/previous field).
            deps.accessibilityManager.injectKey(CGKeyCode(kVK_Tab), flags: mode == .all ? .maskShift : [])

        case .none:
            // No ghost was showing, or the acceptance guardrail dropped it because focus drifted
            // since it was generated (never insert into a different field).
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
            // In assistant-prefill mode the ghost is only what comes AFTER the cursor — a mid-word
            // ghost "ting" completes the "Wri" already in the field — so this is always an
            // insertion, never a replacement (see AcceptPlan).
            guard let plan = AcceptPlan.make(
                ghost: ghost,
                mode: mode,
                trailingSpaceAtEnd: deps.settings.addSpaceAfterAcceptedWord
            ) else {
                deps.overlayController.hide()
                return
            }
            if let element = deps.accessibilityManager.focusedElement() {
                deps.accessibilityManager.insertCompletion(plan.insertion, into: element)
            } else {
                deps.accessibilityManager.injectText(plan.insertion)
            }
            // KV cache is deliberately KEPT here. Accepting appends text to the prompt exactly like
            // typing does: the next `complete()` first trims the cache's generated-token tail back
            // to the tracked prompt (WP-5 reconcile), then `PromptCacheValidity.decide` reuses it
            // if the new prompt still starts with the cached tokens and rebuilds if the boundary
            // re-tokenized differently. Dropping it forced a full re-prefill after every Tab.

            deps.keyMonitor.keystrokeBuffer.appendAccepted(plan.insertion)
            // A2: typing history is written only when "Collect inputs" (and this app's
            // "Record typing history", B5) allow it — the toggle stops collection, not just use.
            if deps.currentPolicy.recordHistory {
                let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                let accepted = plan.acceptedText
                Task { @MainActor in try? deps.historyStore.record(accepted: accepted, appName: appName) }
            }
            deps.recordSuggestionEvent(
                kind: .accepted,
                ghostText: plan.acceptedText,
                metadata: mode == .all ? "all" : "word"
            )

            // Keep the rest of the suggestion visible for the next Tab, under the epoch the ghost
            // was generated at (acceptOutcome left mode untouched for `.acceptWord`).
            guard case .mlCompletion(_, let generationEpoch) = deps.overlayController.mode else { return }
            if plan.remaining.isEmpty {
                // Accepted the last word — hide, then immediately request a fresh suggestion for
                // the new context so the next Tab has something to accept.
                deps.overlayController.hide()
                deps.completionPipeline.keystrokeReceived()
            } else {
                // `acceptedText:` is exactly what was inserted — WP-2 needs it to keep a mirror
                // ghost's stored `textBeforeCursor` in sync with what's on screen now.
                deps.overlayController.continueShowingML(
                    ghost: plan.remaining,
                    epoch: generationEpoch,
                    cursorRect: deps.accessibilityManager.inlineCursorRect(),
                    acceptedText: plan.insertion
                )
            }
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
