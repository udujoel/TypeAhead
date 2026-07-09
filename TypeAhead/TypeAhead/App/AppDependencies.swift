import AppKit
import os

@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    private let logger = Logger(subsystem: "app.typeahead", category: "AppDependencies")

    let settings = AppSettings()
    let accessibilityManager = AccessibilityManager()
    let inferenceEngine = InferenceEngine()
    let completionOverlay = CompletionOverlay()
    let historyStore = HistoryStore()
    /// Single owner of overlay mode (WS3) — replaces the formerly-scattered
    /// `spellCorrectionLength` / `emojiReplacementLength` / `suggestionEpoch` vars plus manual
    /// `keyMonitor.isOverlayVisible` bookkeeping at each call site. `AppDelegate` and
    /// `runCompletion` below go through this for every overlay show/update/hide.
    lazy var overlayController = OverlayController(
        panel: completionOverlay,
        keyMonitor: keyMonitor,
        onPlacementSuppressed: { [weak self] in
            self?.recordSuggestionEvent(kind: .rejected, ghostText: "", metadata: "placementSuppressed")
        }
    )
    let eventStore = SuggestionEventStore()
    /// Last-50 full-detail ring buffer for the Diagnostics settings pane. In-memory only —
    /// never persisted (privacy: full prompt/ghost text must never touch disk). See
    /// `SuggestionEventStore` for the persisted, lengths-only counterpart.
    let debugBuffer = SuggestionDebugBuffer()
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
    /// be accepted into a different field. See `handleFocusChange()`. The epoch a shown suggestion
    /// was generated in now lives on `overlayController.mode` itself (WS3) rather than in a
    /// separate `suggestionEpoch` var — `OverlayStateMachine.acceptRequested` reads it from there.
    let focusEpoch = FocusEpoch()

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
        if overlayController.mode.isVisible {
            overlayController.hide(animated: false)
        }
        focusEpoch.focusChanged()
    }

    /// Records a suggestion-lifecycle event to both the persisted `eventStore` (lengths only)
    /// and the in-memory `debugBuffer` (full detail, for Diagnostics). Fire-and-forget: the
    /// SwiftData write happens in a detached Task so it never blocks the caller's hot path
    /// (keystroke handling / Tab acceptance). Reads the frontmost app fresh at call time —
    /// call sites are all synchronous UI-thread reactions to the ghost that was just shown/
    /// acted on, so frontmost app hasn't had a chance to change out from under them.
    func recordSuggestionEvent(
        kind: SuggestionEventKind,
        promptTail: String = "",
        ghostText: String,
        latencyMs: Double = 0,
        metadata: String = ""
    ) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let appName = settings.appRegistry[bundleID]?.displayName
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
            ?? bundleID

        debugBuffer.record(SuggestionDebugEntry(
            kind: kind,
            appName: appName,
            promptTail: promptTail,
            ghostText: ghostText,
            latencyMs: latencyMs,
            metadata: metadata
        ))

        let event = SuggestionEvent(
            kind: kind,
            appName: appName,
            bundleID: bundleID,
            modelID: settings.activeModelID,
            latencyMs: latencyMs,
            promptTailLength: promptTail.count,
            ghostTextLength: ghostText.count,
            metadata: metadata
        )
        let store = eventStore
        Task { @MainActor in try? store.record(event) }
    }

    private var screenContextCache: CompletionCoordinator.ScreenContextCache?
    private let screenContextCacheTTL: TimeInterval = 2.0

    private func runCompletion() async {
        // Latency measurement (WS2): stamped here, at the moment the debounced pipeline fires
        // and runCompletion actually starts running — NOT at the original keystroke. The
        // debounce/max-wait interval is a deliberate, configurable wait (settings.completionDelay),
        // not processing latency; measuring from here to first ghost paint isolates the part
        // that's actually a perf signal (context read + fast-path lookup or inference time).
        let generationStart = Date()

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
            guard CompletionCoordinator.shouldRunCycle(policy: currentPolicy) else { return }
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
        // can't be accepted after a later focus change lands it in the wrong field. Read fresh
        // here (rather than cached) and passed to each show* call below — `OverlayController`
        // stores it on the mode itself now (WS3), replacing the old standalone `suggestionEpoch`
        // var. No explicit "reset spell/emoji flags" is needed either: the overlay mode is fully
        // derived through explicit show/hide transitions (never a stale flag to zero out), and
        // any previous spell/emoji ghost was already hidden by `onKeystroke` the moment the user
        // typed anything (spell/emoji ghosts never type-through past divergence — see
        // `OverlayStateMachine.keystroke`), so by the time a new cycle reaches this point a
        // leftover spell/emoji mode can't still be showing.
        let cycleEpoch = focusEpoch.epoch

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

        // Fast-path selection (WS3, CompletionCoordinator.selectFastPath): spell-correction and
        // emoji-shortcode detection are mutually exclusive by construction — TypoDetector only
        // matches a trailing all-letters word with no ':' prefix, EmojiSuggester only matches
        // text ending in ":shortcode" with no space after the colon — so at most one of
        // `spellFix` / `emojiShortcode`+`emojiMatch` is ever non-nil for the same cursor
        // position. `selectFastPath` picks spell first when both were somehow present, matching
        // the original code's spell-checked-before-emoji ordering.
        //
        // Both detectors run even when no ML model is loaded (checked further below); neither
        // needs the inference engine.
        let spellFix = TypoDetector.correction(in: context.textBeforeCursor)
        let emojiShortcode: String? = EmojiSuggester.isEmojiMode(textBeforeCursor: context.textBeforeCursor)
            ? EmojiSuggester.shortcode(from: context.textBeforeCursor)
            : nil
        let emojiMatch = emojiShortcode.flatMap { EmojiSuggester.suggest(shortcode: $0).first }

        switch CompletionCoordinator.selectFastPath(spellFix: spellFix, emojiShortcode: emojiShortcode, emojiMatch: emojiMatch) {
        case .spell(let fix):
            // Tab acceptance uses replaceCurrentWord to swap the misspelled word in-place.
            if let placement = accessibilityManager.cursorScreenRect() {
                let fontSize = accessibilityManager.focusedFontSize()
                inferenceEngine.cancelCurrent()
                logger.info("placement tier=\(placement.tier.rawValue, privacy: .public) presentation=\(String(describing: placement.presentation), privacy: .public)")
                logger.debug("spell correction: '\(fix.original, privacy: .private)' -> '\(fix.suggestion, privacy: .private)'")
                overlayController.showSpell(
                    ghost: fix.suggestion,
                    replaceLen: fix.misspelledLength,
                    epoch: cycleEpoch,
                    cursorRect: placement.rect,
                    fontSize: fontSize,
                    presentation: placement.presentation
                )
                guard placement.presentation != .suppress else { return }
                recordSuggestionEvent(
                    kind: .shown,
                    promptTail: String(context.textBeforeCursor.suffix(40)),
                    ghostText: fix.suggestion,
                    latencyMs: Date().timeIntervalSince(generationStart) * 1000,
                    metadata: "spellCorrection,tier=\(placement.tier.rawValue)"
                )
                return
            }
            // Cursor rect unavailable — matches the original: no early return here, falls
            // through toward the ML path below rather than aborting the cycle.

        case .emoji(let shortcode, let emoji):
            // Tab acceptance uses replaceCurrentWord to swap the `:shortcode` for the emoji.
            if let placement = accessibilityManager.cursorScreenRect() {
                let fontSize = accessibilityManager.focusedFontSize()
                inferenceEngine.cancelCurrent()
                logger.info("placement tier=\(placement.tier.rawValue, privacy: .public) presentation=\(String(describing: placement.presentation), privacy: .public)")
                logger.debug("emoji suggestion for shortcode '\(shortcode, privacy: .private)' at \(placement.rect.origin.debugDescription, privacy: .public)")
                overlayController.showEmoji(
                    ghost: emoji,
                    replaceLen: 1 + shortcode.count,  // ":" + shortcode
                    epoch: cycleEpoch,
                    cursorRect: placement.rect,
                    fontSize: fontSize,
                    presentation: placement.presentation
                )
                guard placement.presentation != .suppress else { return }
                recordSuggestionEvent(
                    kind: .shown,
                    promptTail: String(context.textBeforeCursor.suffix(40)),
                    ghostText: emoji,
                    latencyMs: Date().timeIntervalSince(generationStart) * 1000,
                    metadata: "emoji,tier=\(placement.tier.rawValue)"
                )
                return
            }
            // Cursor rect unavailable — falls through, same as the spell case above.

        case .none:
            break
        }

        // ML inference requires the model to be loaded.
        guard inferenceEngine.isLoaded else { return }

        // Placement confidence (WS5): read the caret placement BEFORE any of the expensive
        // ML-path work below (screen-context OCR capture, prompt assembly, personalization,
        // and above all the MLX generation itself). A `.suppress` placement means
        // `OverlayController.showOrUpdateML` would no-op every streamed token — the ghost can
        // never paint — so running inference would burn battery/latency for nothing. Record the
        // same `placementSuppressed` event `OverlayController` fires from its no-op show (that
        // call site is never reached on this path once we early-return here), then bail.
        // Reading the rect this early does mean it's a few hundred ms staler by first paint than
        // the pre-WS5 read-just-before-complete — acceptable: the rect is already held fixed
        // across the whole streaming generation anyway.
        guard let placement = accessibilityManager.cursorScreenRect() else { return }
        logger.info("placement tier=\(placement.tier.rawValue, privacy: .public) presentation=\(String(describing: placement.presentation), privacy: .public)")
        guard CompletionCoordinator.shouldRunInference(presentation: placement.presentation) else {
            recordSuggestionEvent(kind: .rejected, ghostText: "", metadata: "placementSuppressed")
            return
        }

        // Screen context: OCR the frontmost window to give the model ambient topic signal.
        // Cache for 2s so rapid keystrokes don't re-capture on every completion.
        let screenContext: String?
        if settings.useScreenshotContext {
            let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if CompletionCoordinator.shouldUseCachedScreenContext(
                cache: screenContextCache,
                now: Date(),
                ttl: screenContextCacheTTL,
                currentBundleID: currentBundleID
            ), let cache = screenContextCache {
                screenContext = cache.text
            } else {
                let extracted = await ScreenshotContextProvider.captureAndExtractText()
                screenContext = extracted
                screenContextCache = extracted.map {
                    CompletionCoordinator.ScreenContextCache(text: $0, at: Date(), bundleID: currentBundleID)
                }
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

        // Placement (rect + tier) was read before the awaits above — see the WS5 early-out at the
        // top of the ML path.
        let cursorRect = placement.rect
        let fontSize = accessibilityManager.focusedFontSize()
        // Snapshot the epoch this generation belongs to (set at the top, before the awaits above).
        // The onUpdate hop below runs on a *later* main-actor turn, so a focus change can land in
        // between — guard the paint on the epoch so a stale ghost can't flash in the new field.
        let generationEpoch = cycleEpoch
        logger.debug("completion request: source=\(source, privacy: .public) prompt='\(prompt.suffix(60), privacy: .private)' suffix='\(suffix.prefix(40), privacy: .private)' persona=\(personaNote != nil, privacy: .public) cursor=\(cursorRect.debugDescription, privacy: .public)")
        let promptTail = String(context.textBeforeCursor.suffix(40))

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
                let firstPaint = overlayController.showOrUpdateML(
                    ghost: full,
                    epoch: generationEpoch,
                    cursorRect: cursorRect,
                    fontSize: fontSize,
                    presentation: placement.presentation
                )
                // Only the FIRST paint of a generation cycle counts as "shown" — every subsequent
                // streamed token update goes through the update-in-place branch inside
                // `showOrUpdateML`, which intentionally does not re-record. A `.suppress`
                // presentation never reaches here at all — the WS5 early-out above returns before
                // inference even starts (and records `placementSuppressed` itself).
                if firstPaint {
                    logger.debug("overlay.show '\(full.prefix(40), privacy: .private)' at \(cursorRect.origin.debugDescription, privacy: .public)")
                    recordSuggestionEvent(
                        kind: .shown,
                        promptTail: promptTail,
                        ghostText: full,
                        latencyMs: Date().timeIntervalSince(generationStart) * 1000,
                        metadata: "ml,tier=\(placement.tier.rawValue)"
                    )
                }
            }
        } onComplete: {}
    }
}
