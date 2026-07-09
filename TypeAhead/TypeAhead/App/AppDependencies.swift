import AppKit

@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    let settings = AppSettings()
    let accessibilityManager = AccessibilityManager()
    let inferenceEngine = InferenceEngine()
    let completionOverlay = CompletionOverlay()
    let historyStore = HistoryStore()
    lazy var modelManager = ModelManager(inferenceEngine: inferenceEngine, settings: settings)
    lazy var personalizationEngine = PersonalizationEngine(historyStore: historyStore)
    lazy var completionPipeline: CompletionPipeline = CompletionPipeline(
        debounceInterval: settings.completionDelay,
        enabled: settings.completionsEnabled
    ) { [weak self] in
        await self?.runCompletion()
    }
    let keyMonitor = KeyEventMonitor()

    /// Bumps whenever focus moves to a different app/field. Guards against off-topic suggestions:
    /// stale context is dropped on a change, and a suggestion stamped with an earlier epoch can't
    /// be accepted into a different field. See `handleFocusChange()` / `suggestionEpoch`.
    let focusEpoch = FocusEpoch()

    /// The epoch the currently-shown suggestion was generated in. `onTabPressed` refuses to insert
    /// it once `focusEpoch` has moved past this (focus drifted to another field).
    var suggestionEpoch: Int = 0

    /// The resolved per-app policy for the frontmost app, recomputed at the top of every
    /// `runCompletion` cycle. `AppDelegate`'s Tab handler reads `tabKeyDisabled` from this to
    /// decide whether to accept or pass Tab through as a literal keystroke (see AppPolicyResolver).
    var currentPolicy = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: nil)

    init() {
        // Wire on-device Vision caret detection for Electron/Chromium apps with unreliable AX
        // caret bounds. Capture lives here so the ScreenCaptureKit dependency stays app-only.
        accessibilityManager.enableVisionCapture { await ScreenshotContextProvider.captureActiveWindow() }

        // Reset context the moment the user switches apps, so text typed in one app can't leak
        // into a suggestion for the next. (Field switches *within* an app are caught on the
        // completion path via `AccessibilityManager.focusedElementChanged()`.) The notification
        // is delivered on the main queue; hop onto the main actor via the shared singleton to stay
        // Swift-6 concurrency-clean without capturing non-Sendable `self`.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AppDependencies.shared.handleFocusChange() }
        }
    }

    /// Drop stale context when focus moves to a different app/field: clear the keystroke buffer so
    /// a previous field's text can't leak into the next suggestion, cancel any in-flight
    /// generation, hide the ghost, and bump the focus epoch (so a suggestion made for the old
    /// field can't be accepted into the new one).
    func handleFocusChange() {
        keyMonitor.keystrokeBuffer.clear()
        inferenceEngine.cancelCurrent()
        if keyMonitor.isOverlayVisible {
            keyMonitor.isOverlayVisible = false
            completionOverlay.hide(animated: false)
        }
        focusEpoch.focusChanged()
    }

    private var screenContextCache: (text: String, at: Date, bundleID: String)?
    private let screenContextCacheTTL: TimeInterval = 2.0

    /// Non-zero when the overlay shows a spelling correction rather than an ML completion.
    /// Counts the characters of the misspelled word that Tab must replace.
    /// Reset to 0 at the start of every runCompletion cycle.
    var spellCorrectionLength: Int = 0

    /// Non-zero when the current overlay shows an emoji suggestion rather than an ML
    /// completion. Counts the characters of the `:shortcode` that Tab must replace
    /// (e.g. `:wave` → 5). Reset to 0 at the start of every runCompletion cycle.
    var emojiReplacementLength: Int = 0

    private func runCompletion() async {
        // Resolve the effective per-app policy first — before any context reads or inference —
        // so excluded/disabled apps pay zero cost. Auto-register the app (first sighting) so it
        // shows up in the Apps settings pane, then combine the legacy exclusion list with any
        // explicit per-app override via AppPolicyResolver (override always wins; see CLAUDE.md
        // "Per-app exception list always takes precedence over global toggle" — the resolver
        // generalizes that rule to also honor an explicit per-app override).
        if let frontApp = NSWorkspace.shared.frontmostApplication, let bundleID = frontApp.bundleIdentifier {
            settings.registerAppIfNeeded(bundleID: bundleID, displayName: frontApp.localizedName ?? bundleID)
            let excluded = settings.exceptionList.isExcluded(bundleID: bundleID)
            let override = settings.appRegistry[bundleID]?.override
            currentPolicy = AppPolicyResolver.resolve(
                globalCompletionsEnabled: settings.completionsEnabled,
                excludedByList: excluded,
                override: override
            )
            guard currentPolicy.completionsEnabled else { return }
        } else {
            currentPolicy = AppPolicyResolver.resolve(
                globalCompletionsEnabled: settings.completionsEnabled,
                excludedByList: false,
                override: nil
            )
        }

        // Focus hygiene: if the user moved to a different field since the last cycle, drop stale
        // context (buffer/overlay/in-flight generation) before building a new prompt — otherwise a
        // previous field's text leaks in and the model goes off-topic. App switches are handled
        // separately by the NSWorkspace observer; this catches field switches *within* one app.
        //
        // Gated to reliable-AX apps: native AppKit/UIKit apps return a stable AX element ref for
        // the same field (CFEqual holds across reads), but Electron/Chromium apps often recreate
        // their AX elements per query, so CFEqual would report a phantom change every cycle —
        // flickering the overlay and tripping the acceptance guardrail. For those apps the
        // app-switch observer is the (robust) reset; we skip the per-field check.
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if !AppInsertionPolicy.unreliableCaretBounds(forBundleID: frontBundleID),
           accessibilityManager.focusedElementChanged() {
            handleFocusChange()
        }
        // Stamp every suggestion shown this cycle (spell/emoji/ML) with the current epoch so it
        // can't be accepted after a later focus change lands it in the wrong field.
        suggestionEpoch = focusEpoch.epoch

        spellCorrectionLength = 0
        emojiReplacementLength = 0

        // Read the text around the cursor. Prefer the Accessibility API (full
        // field contents); fall back to the keystroke buffer for apps where AX
        // is unavailable (e.g. some Electron apps).
        // Context reading happens before the model-loaded guard so both fast-paths
        // (spell correction and emoji lookup) can run even when no ML model is loaded.
        let context: TextContext
        let source: String
        if let axContext = accessibilityManager.readTextContext() {
            context = axContext
            source = "AX"
        } else {
            let bufferText = keyMonitor.keystrokeBuffer.text
            guard bufferText.count >= 3 else { return }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            context = TextContext(textBeforeCursor: bufferText, textAfterCursor: "", appName: appName, windowTitle: "")
            source = "buffer"
        }

        // Spell-correction fast-path: when the last word before the cursor is misspelled,
        // bypass ML inference and surface the NSSpellChecker suggestion as ghost text.
        // Tab acceptance uses replaceCurrentWord to swap the misspelled word in-place.
        // Runs even when no ML model is loaded.
        if let fix = TypoDetector.correction(in: context.textBeforeCursor),
           let cursorRect = accessibilityManager.cursorScreenRect() {
            let fontSize = accessibilityManager.focusedFontSize()
            spellCorrectionLength = fix.misspelledLength
            inferenceEngine.cancelCurrent()
            print("📝 spell '\(fix.original)' → '\(fix.suggestion)'")
            completionOverlay.show(text: fix.suggestion, near: cursorRect, fontSize: fontSize)
            keyMonitor.isOverlayVisible = true
            return
        }

        // Emoji fast path: when the user types `:shortcode`, bypass ML inference entirely
        // and surface the matching emoji as ghost text.  Tab acceptance uses replaceCurrentWord
        // to swap the `:shortcode` for the emoji.  emojiReplacementLength encodes how many
        // characters to delete (1 colon + shortcode length).
        // Runs even when no model is loaded — emoji lookup needs no inference engine.
        if EmojiSuggester.isEmojiMode(textBeforeCursor: context.textBeforeCursor),
           let shortcode = EmojiSuggester.shortcode(from: context.textBeforeCursor),
           let emoji = EmojiSuggester.suggest(shortcode: shortcode).first,
           let cursorRect = accessibilityManager.cursorScreenRect() {
            let fontSize = accessibilityManager.focusedFontSize()
            emojiReplacementLength = 1 + shortcode.count  // ":" + shortcode
            inferenceEngine.cancelCurrent()
            print("😀 emoji '\(emoji)' for :\(shortcode) at \(cursorRect.origin)")
            completionOverlay.show(text: emoji, near: cursorRect, fontSize: fontSize)
            keyMonitor.isOverlayVisible = true
            return
        }

        // ML inference requires the model to be loaded.
        guard inferenceEngine.isLoaded else { return }

        // Screen context: OCR the frontmost window to give the model ambient topic signal.
        // Cache for 2s so rapid keystrokes don't re-capture on every completion.
        let screenContext: String?
        if settings.useScreenshotContext {
            let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if let cache = screenContextCache,
               Date().timeIntervalSince(cache.at) < screenContextCacheTTL,
               cache.bundleID == currentBundleID {
                screenContext = cache.text
            } else {
                let extracted = await ScreenshotContextProvider.captureAndExtractText()
                screenContext = extracted
                screenContextCache = extracted.map { (text: $0, at: Date(), bundleID: currentBundleID) }
            }
        } else {
            screenContext = nil
            screenContextCache = nil
        }

        // Clipboard context: honor the "Use Clipboard Context" toggle for real (it used to be
        // wired to nothing — see CLAUDE.md history). Cap at 200 chars and run it through the
        // same OCR-quality hygiene screen context uses, so a copied password/token/garbage
        // blob doesn't get echoed into a suggestion. ContextBuilder re-checks readability on
        // its own 120-char excerpt as defense-in-depth.
        let clipboardContext: String?
        if settings.useClipboardContext,
           let clipboard = ClipboardContextProvider.current() {
            let capped = String(clipboard.prefix(200))
            clipboardContext = OCRTextQuality.isLikelyReadable(capped) ? capped : nil
        } else {
            clipboardContext = nil
        }

        // Require a minimum typed prefix before firing. Check textBeforeCursor directly —
        // NOT the assembled prompt — so that screen context (which can be 120+ chars of OCR
        // text) doesn't inflate the count past the threshold when the user has only typed
        // 1-2 characters. 8 chars = one meaningful word + space.
        guard context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { return }

        // Suppress immediately after a sentence terminator (. ! ?). The model has no useful
        // signal for the next clause until the user starts typing it.
        guard !ContextBuilder.shouldSuppressAtSentenceEnd(textBeforeCursor: context.textBeforeCursor) else { return }

        let prompt = ContextBuilder.buildPrompt(
            context: context,
            clipboard: clipboardContext,
            history: [],
            customInstructions: settings.customInstructions,
            screenContext: screenContext
        )

        // Fill-in-middle context: only the AX path knows what's after the cursor.
        // The keystroke-buffer fallback has no suffix, so this stays empty there.
        let suffix = ContextBuilder.buildSuffix(context: context)

        // Personalization: build the system instruction note from custom instructions
        // + frequency-weighted history examples. Gate on `storeInputHistory` so that
        // disabling the "Collect inputs" toggle makes the history opt-out effective —
        // no already-recorded words continue to be injected when the user turns it off.
        let historyExamples: [String]
        if settings.storeInputHistory {
            historyExamples = await personalizationEngine.examples(
                strength: settings.personalizationStrength,
                limit: 5
            )
        } else {
            historyExamples = []
        }
        let personaNote = PersonalizationEngine.buildPersonaNote(
            customInstructions: settings.customInstructions,
            examples: historyExamples,
            appStyleInstruction: currentPolicy.styleInstruction
        )

        guard let cursorRect = accessibilityManager.cursorScreenRect() else { return }
        let fontSize = accessibilityManager.focusedFontSize()
        // Snapshot the epoch this generation belongs to (set at the top, before the awaits above).
        // The onUpdate hop below runs on a *later* main-actor turn, so a focus change can land in
        // between — guard the paint on the epoch so a stale ghost can't flash in the new field.
        let generationEpoch = suggestionEpoch
        print("⌨️ [\(source)] prompt='\(prompt.suffix(60))' suffix='\(suffix.prefix(40))' persona=\(personaNote != nil) cursor=\(cursorRect)")

        inferenceEngine.complete(
            prompt: prompt,
            suffix: suffix,
            maxTokens: settings.completionLength.maxTokens,
            maxWords: settings.completionLength.maxWords,
            personaNote: personaNote
        ) { [weak self] full in
            // Called on the model executor — hop to main to touch UI.
            Task { @MainActor [weak self] in
                guard let self, !full.isEmpty else { return }
                // Focus moved since this generation started (handleFocusChange bumped the epoch and
                // already hid the overlay). This callback was scheduled before that and would
                // otherwise re-show the prior field's suggestion in the new one. Drop it.
                guard focusEpoch.mayAccept(stampedEpoch: generationEpoch) else { return }
                if keyMonitor.isOverlayVisible, !completionOverlay.currentText.isEmpty {
                    completionOverlay.update(text: full, near: cursorRect)
                } else {
                    print("👻 overlay.show '\(full.prefix(40))' at \(cursorRect.origin)")
                    completionOverlay.show(text: full, near: cursorRect, fontSize: fontSize)
                    keyMonitor.isOverlayVisible = true
                }
            }
        } onComplete: {}
    }
}
