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

    /// Word alternatives (⌥↓): the numbered list, the request it belongs to, and what the last ML
    /// generation was asked so alternatives can re-sample the same prompt (a cache replay).
    let alternativesPanel = AlternativesPanel()
    private var alternativesRequestID = 0
    private var alternativesPartialWord = ""
    private var lastInference: InferenceRequest?

    /// B2: set when Escape dismisses a ghost; while active, `runCompletion` shows nothing.
    var dismissCooldown: DismissCooldown?

    /// The effective policy for `bundleID` (nil = no identifiable frontmost app) from the current
    /// settings. The one place the global toggles, legacy exclusion list, and per-app override are
    /// combined — `runCompletion`, the status menu, and the per-app shortcut all go through here.
    ///
    /// `siteDomain` is the matched website rule (browsers only, see `currentSiteDomain`); its
    /// fields layer over the browser's own override.
    func resolvePolicy(bundleID: String?, siteDomain: String? = nil) -> ResolvedPolicy {
        let appOverride = bundleID.flatMap { settings.appRegistry[$0]?.override }
        let override = siteDomain.flatMap { settings.siteRules[$0] }.map { $0.layered(over: appOverride) } ?? appOverride
        return AppPolicyResolver.resolve(
            globalCompletionsEnabled: settings.completionsEnabled,
            excludedByList: bundleID.map { settings.exceptionList.isExcluded(bundleID: $0) } ?? false,
            override: override,
            globalRecordHistory: settings.storeInputHistory
        )
    }

    /// The website rule covering the page focused in a browser, or nil. Costs nothing unless the
    /// user has added a site rule and a browser is in front.
    func currentSiteDomain(bundleID: String) -> String? {
        guard !settings.siteRules.isEmpty, SiteRules.isBrowser(bundleID: bundleID) else { return nil }
        return SiteRules.matchingDomain(host: accessibilityManager.focusedWebHost(), in: settings.siteRules.keys)
    }

    init() {
        // Wire on-device Vision caret detection for Electron/Chromium apps with unreliable AX
        // caret bounds. Capture lives here so the ScreenCaptureKit dependency stays app-only.
        accessibilityManager.enableVisionCapture { await ScreenshotContextProvider.captureActiveWindow() }
        // B9: per-app "Improve compatibility" feeds the insertion/caret decisions.
        accessibilityManager.compatibilityMode = { [weak self] bundleID in
            self?.settings.appRegistry[bundleID]?.override.compatibilityMode ?? false
        }

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
        syncPipelineWithSettings()
    }

    /// A6: the pipeline's debounce was captured once at launch, so moving the Trigger Delay slider
    /// did nothing until a relaunch. Observation re-arms after every change.
    private func syncPipelineWithSettings() {
        withObservationTracking {
            completionPipeline.debounceInterval = settings.completionDelay
        } onChange: {
            Task { @MainActor in AppDependencies.shared.syncPipelineWithSettings() }
        }
    }

    /// Drop stale context when focus moves to a different app/field: clear the keystroke buffer so
    /// a previous field's text can't leak into the next suggestion, cancel any in-flight
    /// generation, hide the ghost, and bump the focus epoch (so a suggestion made for the old
    /// field can't be accepted into the new one).
    func handleFocusChange() {
        keyMonitor.keystrokeBuffer.clear()
        inferenceEngine.cancelCurrent()
        inferenceEngine.invalidateCache()
        if overlayController.mode.isVisible {
            overlayController.hide(animated: false)
        }
        focusEpoch.focusChanged()
        dismissCooldown = nil  // an Escape in the previous field shouldn't mute the new one
        closeWordAlternatives()
        // WP-5 (P1): drop the screen-context OCR cache on every focus change (app switch or
        // in-field switch) rather than relying solely on the TTL below. This is the actual
        // "new field/app gets fresh context" guarantee; the TTL just bounds how stale a
        // same-field re-read can get between focus changes, so it can be generous.
        screenContextCache = nil
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

    // WP-5 (P1): was 2.0s. At 2s, any OCR drift (including the ghost overlay itself appearing in
    // the screenshot) changes prompt token 0 (`[Screen: ...]` is prepended to the prompt head —
    // see ContextBuilder.buildPrompt), forcing a full KV-cache rebuild every <=2s even when the
    // user hasn't changed fields. `handleFocusChange` above now invalidates this cache on every
    // focus/app change, which is the real correctness boundary ("new field/app gets fresh
    // context") — the TTL here only bounds staleness of a same-field re-read between those
    // focus changes, so it can be generous without letting stale context leak across fields.
    private var screenContextCache: CompletionCoordinator.ScreenContextCache?
    private let screenContextCacheTTL: TimeInterval = 30.0

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
            currentPolicy = resolvePolicy(bundleID: bundleID, siteDomain: currentSiteDomain(bundleID: bundleID))
            guard CompletionCoordinator.shouldRunCycle(policy: currentPolicy) else { return }
        } else {
            currentPolicy = resolvePolicy(bundleID: nil)
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
        if !AppInsertionPolicy.unreliableCaretBounds(forBundleID: frontBundleID, compatibilityMode: currentPolicy.compatibilityMode),
           accessibilityManager.focusedElementChanged() {
            handleFocusChange()
        }
        // B2: Escape asked for a short break from suggestions — honor it until it expires or the
        // user reaches the next word boundary (see DismissCooldown). Checked after the field-switch
        // reset above, which clears it: an Escape in one field shouldn't mute the next.
        if let cooldown = dismissCooldown {
            if cooldown.isActive(now: Date()) { return }
            dismissCooldown = nil
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

        // WP-2 stale-paint guard / WP-B retry-once (item 3): snapshot the pipeline's validity
        // token now, at cycle start — before the `await ScreenshotContextProvider
        // .captureAndExtractText()` / `personalizationEngine.examples(...)` awaits further down,
        // so a correction key (backspace/arrows) landing DURING those awaits is caught too, not
        // just one that lands after inference starts. `CompletionPipeline.cycleValidityToken`
        // increments on every debounce/max-wait `fire()` (a newer keystroke started a fresher
        // cycle) AND on every `cancel()` (a correction key invalidated this cycle without
        // starting a new one, see `cycleValidityToken`'s doc comment for the "heelp" bug this
        // closes) — so if it's still equal to this snapshot when a paint or a completion arrives,
        // nothing has happened since that would make this generation stale. Combined with
        // `focusEpoch.mayAccept`, this is the staleness guard the instant-dictionary paint, the
        // ML paint path (`onUpdate` below), and the retry path (`onComplete` below) all check
        // before painting/re-firing: either signal moving means abort. (A newer keystroke during
        // attempt 0 would also have called `inferenceEngine.complete` again directly, which
        // cancels `currentTask` — cancellation already skips `onComplete` entirely, per
        // `InferenceEngine.complete`'s `if !Task.isCancelled { onComplete() }` — but `onUpdate`
        // closures already scheduled onto the main actor run regardless of cancellation, which is
        // exactly the "heelp" mechanism: the counter check below is what actually stops those
        // late paints.)
        let cycleValidityToken = completionPipeline.cycleValidityToken

        // English variant: the dictionary used by the spell/word-completion fast paths below and
        // the spelling sentence of the model instruction come from one setting, so they agree.
        let systemSpellLanguage = NSSpellChecker.shared.language()
        let spellLanguage = settings.englishVariant.spellCheckerLanguage(systemLanguage: systemSpellLanguage)
        let britishSpelling = settings.englishVariant.usesBritishSpelling(systemLanguage: systemSpellLanguage)

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
            // B8: AX refused because the field holds a secret — the buffer may contain exactly
            // what was typed into it. Drop it and suggest nothing.
            if accessibilityManager.focusedFieldIsSecure {
                keyMonitor.keystrokeBuffer.clear()
                return
            }
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
        let spellFix = TypoDetector.correction(in: context.textBeforeCursor, language: spellLanguage)
        // A10: the "Enable Emoji Suggestions" toggle was never read — honor it here.
        let emojiShortcode: String? = settings.emojiSuggestionsEnabled
            && EmojiSuggester.isEmojiMode(textBeforeCursor: context.textBeforeCursor)
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
                    presentation: placement.presentation,
                    tier: placement.tier,
                    textBeforeCursor: context.textBeforeCursor
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
                    presentation: placement.presentation,
                    tier: placement.tier,
                    textBeforeCursor: context.textBeforeCursor
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

        // B7: with "Mid-line completions" off, stay quiet while the cursor has text after it on
        // the same line (spell/emoji fast paths above still apply — they fix the word itself).
        guard CompletionCoordinator.passesMidLineGate(
            midLineEnabled: settings.midLineCompletionsEnabled,
            textAfterCursor: context.textAfterCursor
        ) else { return }

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

        // WP-B: attempt from the second word on, and NEVER stop attempting after a sentence
        // terminator (. ! ?) — the old `ContextBuilder.shouldSuppressAtSentenceEnd` guard here
        // meant a completion never even attempted at a sentence end. The owner wants suggestions
        // "always... from the second word"; the firmer `PersonalizationEngine.buildInstruction`
        // wording now supports the model starting a fresh sentence instead of trailing off.
        // `shouldSuppressAtSentenceEnd` itself is left in place (unused by this pipeline) for
        // possible future per-app policy use.
        guard CompletionCoordinator.shouldAttemptCompletion(textBeforeCursor: context.textBeforeCursor) else { return }

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
        // Captured separately from `context` (rather than reaching into it from inside the
        // streaming closure below) so the mirror's `MirrorText.compose` always gets the FULL
        // pre-cursor text, not `promptTail`'s already-40-char-clipped tail — a clip that isn't
        // "last line"-aware and could otherwise cut a mirror's typed tail mid-word or across a
        // newline it shouldn't see.
        let mirrorTypedText = context.textBeforeCursor

        func runInference(temperature: Float, attempt: Int) {
            // Tracks whether this attempt ever produced a usable ghost (a non-empty `full` —
            // InferenceEngine.ghostText/GhostText.build already collapses junk output to "").
            // A tiny `@unchecked Sendable` box (same pattern as InferenceEngine's
            // `PromptCacheBox`) because `onUpdate`/`onComplete` are both `@Sendable` and need to
            // share this one flag across the same generation.
            let outcome = GenerationOutcome()

            // WP-8: on the retry (attempt 1), strip the prompt scaffolding — no persona note,
            // no suffix hint in the INSTRUCTION — leaving just the bare `baseInstruction`. The
            // remaining empty-generation cases post-cache-fix correlate with prompt-scaffolding
            // confusion in this small a model rather than an unlucky sample; temperature alone
            // had a poor retry hit rate in dogfooding logs, so give the retry a shorter, more
            // direct instruction instead. This only touches the INSTRUCTION — `suffix` itself is
            // still passed through unchanged below, so the output-side overlap trim
            // (`GhostText.build`'s `suffix` param, via `InferenceEngine.ghostText`) keeps using
            // the real suffix even on retry; we're dropping the suffix from the prompt, not from
            // output hygiene. The retry already pays a full prefill regardless (see `complete`'s
            // doc comment on `temperature`), so a different instruction adds no extra cache cost.
            let isRetry = attempt > 0
            if !isRetry {
                lastInference = InferenceRequest(prompt: prompt, suffix: suffix, personaNote: personaNote,
                                                 maxWords: settings.completionLength.maxWords,
                                                 britishSpelling: britishSpelling)
            }
            inferenceEngine.complete(
                prompt: prompt,
                suffix: suffix,
                maxTokens: settings.completionLength.maxTokens,
                maxWords: settings.completionLength.maxWords,
                personaNote: isRetry ? nil : personaNote,
                instructionSuffix: isRetry ? "" : suffix,
                temperature: temperature,
                britishSpelling: britishSpelling
            ) { [weak self] full in
                // Called on the model executor — hop to main to touch UI.
                Task { @MainActor [weak self] in
                    guard let self, !full.isEmpty else { return }
                    outcome.producedUsableGhost = true
                    // Focus moved since this generation started (handleFocusChange bumped the epoch and
                    // already hid the overlay). This callback was scheduled before that and would
                    // otherwise re-show the prior field's suggestion in the new one. Drop it.
                    guard focusEpoch.mayAccept(stampedEpoch: generationEpoch) else { return }
                    // "heelp" bug (WP-2): this `onUpdate` Task was already hopping to the main
                    // actor when a superseding keystroke landed — cancellation of the underlying
                    // model task doesn't stop a hop already in flight. Without this guard, a late
                    // paint from a cycle the user has since typed past (or corrected away with
                    // backspace) could land AFTER the newer keystroke, producing exactly the
                    // dogfooding bug: ghost text painted onto a field that no longer matches the
                    // prompt it was generated for, then Tab-accepted into garbage ("heelp"). The
                    // retry path below already had this guard; the paint path did not.
                    guard completionPipeline.cycleValidityToken == cycleValidityToken else { return }
                    let firstPaint = overlayController.showOrUpdateML(
                        ghost: full,
                        epoch: generationEpoch,
                        cursorRect: cursorRect,
                        fontSize: fontSize,
                        presentation: placement.presentation,
                        tier: placement.tier,
                        textBeforeCursor: mirrorTypedText
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
            } onComplete: { [weak self] in
                // Called on the model executor (see onUpdate's comment above) — hop to main
                // before touching any AppDependencies state.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard CompletionCoordinator.shouldRetryGeneration(
                        attempt: attempt, producedUsableGhost: outcome.producedUsableGhost
                    ) else { return }
                    // Staleness guards — see the comment on `cycleValidityToken` above: abort the
                    // retry if focus moved on, or a newer keystroke/correction-key already
                    // invalidated this cycle, since either means this prompt is no longer relevant.
                    guard focusEpoch.mayAccept(stampedEpoch: generationEpoch) else { return }
                    guard completionPipeline.cycleValidityToken == cycleValidityToken else { return }
                    // No user text logged — matches the rest of this file's privacy discipline.
                    logger.info("retrying generation: attempt 0 produced no usable ghost, retrying at temperature=0.8")
                    runInference(temperature: 0.8, attempt: 1)
                }
            }
        }

        // WP-7: instant dictionary-based ghost for the word the user is mid-typing, shown
        // through the SAME showOrUpdateML(...) call the ML streaming path uses below — a
        // dictionary word-completion ghost is semantically identical to an ML ghost that
        // continues the current word (no leading space, Tab appends via .acceptWord,
        // type-through advances it, divergence hides it), so there is no new overlay mode
        // here, just an instant source for the existing one. The ML generation started by
        // runInference() below then replaces this ghost in place, through the same
        // update-in-place branch of showOrUpdateML, the moment its first token lands.
        //
        // Placed here (after every gate above: policy, placement suppress,
        // shouldRunInference, the 8-char minimum, and shouldAttemptCompletion) so the
        // instant ghost respects every precondition the ML path respects — it never shows
        // where the ML path wouldn't have attempted anyway. It runs AFTER the
        // `ScreenshotContextProvider.captureAndExtractText()` / `personalizationEngine
        // .examples(...)` awaits above, so a focus change (or a correction key) landing during
        // those awaits is a real hazard here too, not just for the ML paint path below — hence
        // the same two staleness guards, checked against the values snapshotted at cycle start
        // (see the comment on `cycleValidityToken` up top).
        //
        // Mutual exclusion with spell-correction (verified): TypoDetector.correction only
        // fires for a trailing word that is NOT a prefix of any valid dictionary word
        // (isPrefixOfValidWord guard) — so any word for which WordCompleter here finds a
        // completion is, by construction, exactly the case spellFix above would have
        // returned nil for. They can't both fire for the same cursor position. And by
        // this point in the function, both the .spell and .emoji cases above have already
        // `return`ed if they matched — this line is unreached unless CompletionCoordinator
        // .selectFastPath picked neither.
        guard focusEpoch.mayAccept(stampedEpoch: generationEpoch) else { return }
        guard completionPipeline.cycleValidityToken == cycleValidityToken else { return }
        if let partial = ContextBuilder.currentWord(context: context),
           WordCompleter.shouldOfferInstantCompletion(partial: partial),
           let suffix = WordCompleter.completionSuffix(forPartial: partial, language: spellLanguage),
           GhostText.isUsableGhost(suffix) {
            let firstPaint = overlayController.showOrUpdateML(
                ghost: suffix,
                epoch: generationEpoch,
                cursorRect: cursorRect,
                fontSize: fontSize,
                presentation: placement.presentation,
                tier: placement.tier,
                textBeforeCursor: mirrorTypedText
            )
            if firstPaint {
                recordSuggestionEvent(
                    kind: .shown,
                    promptTail: promptTail,
                    ghostText: suffix,
                    latencyMs: Date().timeIntervalSince(generationStart) * 1000,
                    metadata: "dict,tier=\(placement.tier.rawValue)"
                )
            }
        }

        runInference(temperature: 0.5, attempt: 0)
    }
}

/// Tiny mutable box shared between a generation's `onUpdate`/`onComplete` closures (WP-B retry)
/// so `runCompletion` can tell, once a generation finishes, whether it ever produced a usable
/// ghost. `@unchecked Sendable` is deliberate: `InferenceEngine.complete` only ever has one
/// generation in flight per `runInference` call (each call creates its own fresh box), and every
/// read/write of `producedUsableGhost` happens inside a `Task { @MainActor in ... }` hop, so
/// there's no actual concurrent access despite crossing the `@Sendable` closure boundary — same
/// reasoning `InferenceEngine`'s own `PromptCacheBox` documents.
private final class GenerationOutcome: @unchecked Sendable {
    var producedUsableGhost = false
}

// MARK: - Word alternatives (⌥↓, then 1–3)

/// What the last ML suggestion was generated from — re-sampled for word alternatives.
struct InferenceRequest {
    let prompt: String
    let suffix: String
    let personaNote: String?
    let maxWords: Int
    let britishSpelling: Bool
}

extension AppDependencies {
    /// ⌥↓ on a visible ML ghost: list up to three other choices for its first word. A mid-word
    /// ghost gets dictionary completions of the partial word (instant); a new-word ghost gets extra
    /// samples of the same prompt from the model, shown as they arrive.
    func requestWordAlternatives() {
        guard case .mlCompletion(let ghost, let epoch) = overlayController.mode,
              focusEpoch.mayAccept(stampedEpoch: epoch),
              let firstWord = WordAlternatives.firstWord(ofGhost: ghost) else { return }
        let caret = accessibilityManager.inlineCursorRect() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        alternativesRequestID += 1
        let requestID = alternativesRequestID

        let partial = ghost.hasPrefix(" ") ? "" : (currentPartialWord() ?? "")
        alternativesPartialWord = partial
        keyMonitor.isAlternativesVisible = true

        if !partial.isEmpty {
            let language = settings.englishVariant.spellCheckerLanguage(systemLanguage: NSSpellChecker.shared.language())
            let words = WordAlternatives.rank(
                WordCompleter.completions(forPartial: partial, language: language, limit: 12),
                excluding: partial + firstWord, limit: 3)
            guard !words.isEmpty else { closeWordAlternatives(); return }
            alternativesPanel.show(words: words, below: caret)
            return
        }

        guard let request = lastInference, inferenceEngine.isLoaded else { closeWordAlternatives(); return }
        alternativesPanel.show(words: [], below: caret)
        sampleAlternative(round: 0, requestID: requestID, excluding: firstWord, caret: caret,
                          request: request, collected: AlternativeSamples())
    }

    /// One extra model sample; chains up to four rounds until three distinct words are found.
    private func sampleAlternative(round: Int, requestID: Int, excluding firstWord: String, caret: NSRect,
                                   request: InferenceRequest, collected: AlternativeSamples) {
        let latest = SampleText()
        // Same instruction as the original suggestion (same persona, suffix, and word target), so
        // the prompt tokens are identical and the engine replays its cache instead of re-prefilling.
        inferenceEngine.complete(
            prompt: request.prompt,
            suffix: request.suffix,
            maxTokens: 6,
            maxWords: request.maxWords,
            personaNote: request.personaNote,
            temperature: 1.0,
            britishSpelling: request.britishSpelling
        ) { ghost in
            latest.value = ghost
        } onComplete: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, requestID == self.alternativesRequestID, self.alternativesPanel.isVisible else { return }
                if !latest.value.isEmpty { collected.samples.append(latest.value) }
                let words = WordAlternatives.rank(collected.samples, excluding: firstWord, limit: 3)
                if !words.isEmpty { self.alternativesPanel.show(words: words, below: caret) }
                if words.count < 3 && round < 3 {
                    self.sampleAlternative(round: round + 1, requestID: requestID, excluding: firstWord,
                                           caret: caret, request: request, collected: collected)
                } else if words.isEmpty {
                    self.closeWordAlternatives()
                }
            }
        }
    }

    /// 1–3 while the list shows: insert that word in place of the ghost's first word.
    func chooseWordAlternative(at index: Int) {
        defer { closeWordAlternatives() }
        let words = alternativesPanel.words
        guard index < words.count,
              case .mlCompletion(let ghost, let epoch) = overlayController.mode,
              focusEpoch.mayAccept(stampedEpoch: epoch),
              let insertion = WordAlternatives.insertion(
                  for: words[index], ghost: ghost, partialWord: alternativesPartialWord,
                  trailingSpace: settings.addSpaceAfterAcceptedWord) else { return }
        if let element = accessibilityManager.focusedElement() {
            accessibilityManager.insertCompletion(insertion, into: element)
        } else {
            accessibilityManager.injectText(insertion)
        }
        keyMonitor.keystrokeBuffer.appendAccepted(insertion)
        let chosen = words[index]
        if currentPolicy.recordHistory {
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            Task { @MainActor in try? self.historyStore.record(accepted: chosen, appName: appName) }
        }
        recordSuggestionEvent(kind: .accepted, ghostText: chosen, metadata: "alternative")
        overlayController.hide(animated: false)
        completionPipeline.keystrokeReceived()
    }

    func closeWordAlternatives() {
        alternativesRequestID += 1  // stops any sampling still in flight from updating the list
        keyMonitor.isAlternativesVisible = false
        alternativesPanel.hide()
    }

    /// The partial word before the caret (AX first, keystroke buffer as fallback).
    private func currentPartialWord() -> String? {
        if let context = accessibilityManager.readTextContext() {
            return ContextBuilder.currentWord(context: context)
        }
        let buffer = TextContext(textBeforeCursor: keyMonitor.keystrokeBuffer.text, textAfterCursor: "", appName: "", windowTitle: "")
        return ContextBuilder.currentWord(context: buffer)
    }
}

/// Samples collected across one alternatives request's rounds (main-actor only).
@MainActor private final class AlternativeSamples {
    var samples: [String] = []
}

/// Latest streamed text of one sample; written from the engine's `@Sendable` update callback and
/// read on the main actor after `onComplete` — the same one-generation-at-a-time reasoning as
/// `GenerationOutcome`.
private final class SampleText: @unchecked Sendable {
    var value = ""
}
