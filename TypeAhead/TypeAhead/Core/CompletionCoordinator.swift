import Foundation

/// Pure decision logic extracted from `AppDependencies.runCompletion` (WS3).
///
/// `runCompletion` is ~230 lines of AX reads, MLX inference calls, and ScreenCaptureKit OCR
/// interleaved with the decisions that actually determine correctness — which fast path wins,
/// whether the cycle should run at all, whether a cached screen-context OCR result is still
/// good. None of that imperative I/O can move into an SPM target (it needs AppKit's AX APIs,
/// MLXLLM, and ScreenCaptureKit — see `Package.swift`'s exclude list), so a full
/// `CompletionCoordinator` that "runs" the cycle isn't SPM-testable without a large protocol
/// surface duplicating those frameworks.
///
/// Per WS3's fallback guidance, this extracts the DECISION pieces only — the parts a bug most
/// often actually lives in — as pure functions `AppDependencies.runCompletion` now calls instead
/// of inlining the equivalent logic. What stays behind, and why:
/// - AX context reads (`accessibilityManager.readTextContext`), cursor rect, font size: need
///   live AX, not fakeable as pure data without a protocol that's most of `AccessibilityManager`.
/// - `InferenceEngine.complete(...)`: needs MLXLMCommon; SPM excludes `InferenceEngine.swift`.
/// - `ScreenshotContextProvider.captureAndExtractText()`: needs ScreenCaptureKit.
/// - The overlay show/update/hide calls themselves: that's `OverlayController`'s job (see
///   `OverlayController.swift`), already extracted and tested via `OverlayStateMachine`.
enum CompletionCoordinator {

    // MARK: - Policy-disabled early exit

    /// Whether a completion cycle should proceed past policy resolution. Mirrors
    /// `runCompletion`'s `guard currentPolicy.completionsEnabled else { return }` — kept as a
    /// named function (rather than inlining `policy.completionsEnabled`) so the "early exit on
    /// disabled policy" rule has one obvious place to test and read, independent of how
    /// `ResolvedPolicy` gets computed.
    static func shouldRunCycle(policy: ResolvedPolicy) -> Bool {
        policy.completionsEnabled
    }

    // MARK: - Fast-path selection order

    /// Which fast path (if any) a completion cycle should take, given what the spell-checker and
    /// emoji matcher found this cycle. Mirrors `runCompletion`'s two sequential `if let` blocks
    /// exactly: spell-correction is checked (and wins) first; emoji is only considered when no
    /// spell fix was found. Neither fast path needs the ML model loaded — that guard sits after
    /// both of these in `runCompletion` and is untouched by this function.
    enum FastPath: Equatable {
        case spell(TypoFix)
        case emoji(shortcode: String, emoji: String)
        case none
    }

    static func selectFastPath(spellFix: TypoFix?, emojiShortcode: String?, emojiMatch: String?) -> FastPath {
        if let spellFix {
            return .spell(spellFix)
        }
        if let emojiShortcode, let emojiMatch {
            return .emoji(shortcode: emojiShortcode, emoji: emojiMatch)
        }
        return .none
    }

    // MARK: - Placement suppress early-out (WS5)

    /// Whether the ML inference path should run at all given the placement presentation for this
    /// cycle. A `.suppress` placement means the ghost can never paint (`OverlayController` would
    /// no-op every streamed token), so starting an MLX generation would burn battery/latency for
    /// nothing — `runCompletion` early-returns instead, BEFORE building the prompt or calling
    /// `inferenceEngine.complete`. `.inline` and `.mirror` both proceed. The spell/emoji fast
    /// paths don't consult this: they have no inference cost, and their suppress handling (no-op
    /// show + `placementSuppressed` telemetry inside `OverlayController`) already short-circuits.
    static func shouldRunInference(presentation: PlacementPresentation) -> Bool {
        presentation != .suppress
    }

    // MARK: - Second-word gating (WP-B: aggressive, persistent suggestions)

    /// Whether a completion cycle should attempt inference at all, given the text before the
    /// cursor. Replaces the old `ContextBuilder.shouldSuppressAtSentenceEnd` guard in
    /// `runCompletion` — that guard suppressed completions right after `.`/`!`/`?`, so a
    /// generation never even attempted at a sentence end. The owner wants the opposite:
    /// suggestions "always predict... from the second word", including at sentence ends (the
    /// model can start the next sentence — the firmer `PersonalizationEngine.buildInstruction`
    /// wording now supports that).
    ///
    /// True iff `textBeforeCursor` contains at least 2 whitespace-separated tokens that each
    /// contain a letter or digit — pure punctuation tokens (a lone "-" or "..." left over after
    /// splitting on whitespace) don't count as a "word" for this purpose. `ContextBuilder.
    /// shouldSuppressAtSentenceEnd` itself is left in place (function + tests) — retained for
    /// possible future per-app policy use — but `runCompletion` no longer calls it.
    static func shouldAttemptCompletion(textBeforeCursor: String) -> Bool {
        let wordTokens = textBeforeCursor
            .split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        return wordTokens.count >= 2
    }

    // MARK: - Retry-once on unusable generation (WP-B)

    /// Whether `runCompletion` should re-run the same prompt (at a higher temperature) after a
    /// generation completed but produced no usable ghost. True only on the very first attempt
    /// (`attempt == 0`) when nothing usable came out — never on the retry itself, so this can
    /// never recurse more than once regardless of how many times a caller asks.
    static func shouldRetryGeneration(attempt: Int, producedUsableGhost: Bool) -> Bool {
        attempt == 0 && !producedUsableGhost
    }

    // MARK: - Screen-context cache TTL

    /// One cached OCR screen-context read: the extracted text, when it was captured, and which
    /// app's window it came from.
    struct ScreenContextCache: Equatable {
        var text: String
        var at: Date
        var bundleID: String
    }

    /// Whether a cached screen-context OCR result is still usable, or a fresh capture is needed.
    /// Mirrors `runCompletion`'s cache check exactly: usable only within `ttl` of capture AND for
    /// the same frontmost app (switching apps invalidates the cache even if it hasn't expired —
    /// otherwise a stale OCR from the previous app could leak into a new app's prompt).
    static func shouldUseCachedScreenContext(
        cache: ScreenContextCache?,
        now: Date,
        ttl: TimeInterval,
        currentBundleID: String
    ) -> Bool {
        guard let cache else { return false }
        guard now.timeIntervalSince(cache.at) < ttl else { return false }
        return cache.bundleID == currentBundleID
    }
}
