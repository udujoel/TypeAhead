import Foundation
import os
import MLX
import MLXLLM
import MLXLMCommon

enum InferenceError: Error {
    case modelNotLoaded
    case loadFailed(String)
}

/// Runs `operation`, but throws if it doesn't finish within `seconds`. The two
/// children race; whichever finishes first wins and the other is cancelled. This
/// is a backstop so a hung model load surfaces as a recoverable error instead of
/// spinning the UI forever.
private func withLoadTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw InferenceError.loadFailed("load timed out after \(Int(seconds))s")
        }
        guard let result = try await group.next() else {
            throw InferenceError.loadFailed("load produced no result")
        }
        group.cancelAll()
        return result
    }
}

/// Reference box holding the KV-cache reuse state (WS6) that must cross `ModelContainer`'s
/// actor boundary via `container.perform`'s `@Sendable` closure.
///
/// `@unchecked Sendable` is deliberate, not an oversight: `InferenceEngine` is the sole owner,
/// is itself `@MainActor`, and always cancels the previous `currentTask` before starting a new
/// one, so only one completion in flight ever touches this box. `ModelContainer.perform` adds a
/// second layer of serialization on top (its own internal actor executes one closure at a
/// time). The MLXArrays inside `kvCache` are therefore never accessed from two execution
/// contexts concurrently, which is exactly the property `Sendable` exists to guarantee — we're
/// just asserting it by hand instead of getting it from the type system, the same trick
/// MLXLMCommon's own (package-internal, not importable here) `SendableBox` uses.
private final class PromptCacheBox: @unchecked Sendable {
    /// Full token sequence (instruction + prefix) the current `kvCache` was built from.
    var tokens: [Int] = []
    /// The KV cache continued across debounce fires, or nil if there's nothing cached.
    var kvCache: [KVCache]?

    func invalidate() {
        tokens = []
        kvCache = nil
    }
}

@MainActor
final class InferenceEngine {
    private let logger = Logger(subsystem: "app.typeahead", category: "InferenceEngine")
    private let signposter = OSSignposter(subsystem: "app.typeahead", category: "KVCache")

    private(set) var isLoaded = false
    private var container: ModelContainer?
    private var currentTask: Task<Void, Never>?
    private var loadedModelID: String = ""
    private var lastLoggedLoadPct = -1

    // WS6: KV-cache reuse across debounce fires. See PromptCacheValidity (pure, SPM-tested) for
    // the reuse-vs-rebuild decision and PromptCacheBox's doc comment for why this needs its own
    // Sendable box. Invalidated explicitly on model unload (below), focus change
    // (AppDependencies.handleFocusChange -> invalidateCache()), and Tab-accept insertion
    // (AppDelegate's .acceptWord case -> invalidateCache()) — anything that changes the field's
    // text out from under the cached token prefix.
    private let promptCacheBox = PromptCacheBox()

    /// Drops the KV cache and its associated token history. Safe to call even with no model
    /// loaded or no cache built yet. See the call sites listed on `promptCacheBox` above.
    func invalidateCache() {
        promptCacheBox.invalidate()
    }

    // Instruction building is in PersonalizationEngine (pure Swift, SPM-testable without MLXLLM).
    // InferenceEngine delegates to it so the logic can be unit-tested independently.

    var isAvailable: Bool { isLoaded }
    var availabilityDescription: String { isLoaded ? "MLX model loaded" : "No model loaded" }

    // MARK: - Load / Unload

    func loadModel(
        config: ModelConfig,
        progressHandler: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        let modelConfig = ModelConfiguration(id: config.huggingFaceRepo)
        let cached = ModelManager.isModelCached(repoId: config.huggingFaceRepo)
        let start = Date()
        lastLoggedLoadPct = -1
        logger.info("loadModel: \(config.id, privacy: .public) [\(config.huggingFaceRepo, privacy: .public)] cached=\(cached, privacy: .public) — starting")

        do {
            // Load into a LOCAL first; swap it in only after success. A slow or hung
            // load then never tears down the model that's already working. A watchdog
            // timeout converts an indefinite hang into a recoverable error.
            let loaded = try await withLoadTimeout(seconds: 240) { [weak self] in
                try await LLMModelFactory.shared.loadContainer(
                    from: TypeAheadDownloader(),
                    using: TypeAheadTokenizerLoader(),
                    configuration: modelConfig
                ) { progress in
                    Task { @MainActor in
                        self?.logLoadProgress(progress.fractionCompleted)
                        progressHandler(progress.fractionCompleted)
                    }
                }
            }
            container = loaded
            loadedModelID = config.id
            isLoaded = true
            logger.info("loadModel: \(config.id, privacy: .public) ready in \(Int(-start.timeIntervalSinceNow), privacy: .public)s")
        } catch {
            logger.error("loadModel: \(config.id, privacy: .public) failed after \(Int(-start.timeIntervalSinceNow), privacy: .public)s: \(error.localizedDescription, privacy: .public)")
            throw InferenceError.loadFailed(error.localizedDescription)
        }
    }

    /// Logs load/download progress at most once per 10% so a stalled load is visible
    /// (e.g. "stuck at 100% → it's the model load/tokenizer, not the download").
    private func logLoadProgress(_ fraction: Double) {
        let pct = Int(fraction * 100)
        if pct >= lastLoggedLoadPct + 10 || pct >= 100 {
            lastLoggedLoadPct = pct
            logger.info("loadModel progress: \(pct, privacy: .public)%")
        }
    }

    func unloadModel() {
        currentTask?.cancel()
        currentTask = nil
        container = nil
        isLoaded = false
        loadedModelID = ""
        invalidateCache()
    }

    // MARK: - Completion

    /// Generates a completion for `prompt`. `onUpdate` receives the full cleaned
    /// completion text as it grows (call it to refresh the ghost-text overlay).
    /// `onComplete` fires once when generation finishes — unless superseded.
    ///
    /// - Parameter personaNote: Optional persona/style note from PersonalizationEngine
    ///   (customInstructions + frequent history words). Prepended to the base instruction.
    /// - Parameter temperature: sampling temperature for `GenerateParameters`. WP-B: the
    ///   retry-once-on-unusable-generation flow (`AppDependencies.runCompletion`) calls this a
    ///   second time with a higher temperature (0.8) when the first attempt (default 0.5)
    ///   produced no usable ghost — a different sample from the same distribution is often
    ///   enough to escape a degenerate '.'/'...'/empty-line output. NOTE: the retry is NOT a
    ///   cache hit. `box.tokens` after the first attempt is the same length as `newTokens` (the
    ///   prompt didn't change), so `PromptCacheValidity.decide` returns `.rebuild` for an
    ///   identical-length sequence — the retry pays a full prefill, same as the first attempt.
    ///   (WP-5: an earlier version of this comment claimed the retry was a cache hit; it was
    ///   wrong — see the cache-offset reconciliation below for why that mattered.)
    func complete(
        prompt: String,
        suffix: String = "",
        maxTokens: Int,
        maxWords: Int = 0,
        personaNote: String? = nil,
        instructionSuffix: String? = nil,
        temperature: Float = 0.5,
        onUpdate: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard isLoaded, let container else { onComplete(); return }

        currentTask?.cancel()

        // maxWords==0 means "no display cap" (see GhostText's doc comment) — the instruction
        // still needs a concrete number to tell the model, so fall back to the medium default
        // (4) rather than telling it "at most 0 words".
        let instructionTargetWords = maxWords > 0 ? maxWords : 4
        // WP-8: `instructionSuffix` is a separate knob from `suffix` so a caller can strip the
        // suffix hint out of the INSTRUCTION (leaner retry prompt) while `suffix` itself still
        // flows to the output-side overlap trim below (`ghostText`/`GhostText.build`) — those
        // are two different concerns that happened to share one parameter before. Defaults to
        // `suffix` so every existing caller (which doesn't pass `instructionSuffix`) sees
        // identical behavior to before this split.
        let instruction = PersonalizationEngine.buildInstruction(personaNote: personaNote, suffix: instructionSuffix ?? suffix, targetWords: instructionTargetWords)

        // ASSISTANT-PREFILL (assembled in HFBridge): the model turn is seeded with `prompt`
        // and left open, so the instruct model continues the user's own text in-distribution.
        // Raw text made it loop; chat-replying made it ignore the text. The model emits only
        // NEW tokens, so the output IS the continuation — ghostText skips prefix-alignment.
        //
        // WS6: rather than the old two-step container.prepare(input:) + container.generate(...)
        // (which always re-tokenizes and re-prefills the FULL prompt), tokenization and cache
        // reuse now happen together inside one container.perform block so the reuse-vs-rebuild
        // decision and the actual prefill see the exact same token sequence. See PromptCacheBox
        // for why the cache state is boxed, and PromptCacheValidity for the decision logic.
        let box = promptCacheBox
        let signposter = signposter
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": instruction],
            ["role": "user", "content": prompt],
        ]
        // No repetitionPenalty: it penalizes prompt tokens too, which pushed the
        // model toward newline/whitespace output. The maxWords cap handles visible
        // rambling instead. Slightly higher temperature gives real words a better
        // chance over a deterministic newline on short, ambiguous prefixes. WP-B: `temperature`
        // is now a parameter (default 0.5, same as before) so the retry-once flow in
        // `AppDependencies.runCompletion` can re-sample at a higher temperature (0.8) when the
        // first attempt produced no usable ghost.
        let params = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: 0.9
        )

        currentTask = Task {
            do {
                let signpostID = signposter.makeSignpostID()
                let interval = signposter.beginInterval("complete", id: signpostID)

                let stream = try await container.perform { context -> AsyncStream<Generation> in
                    // WP-5 (P0): reconcile the cache's real offset with box.tokens BEFORE
                    // deciding reuse-vs-rebuild. MLXLMCommon.generate's TokenIterator.step()
                    // mutates the cache (advances its offset) on EVERY generated token, but
                    // box.tokens only ever stores the PROMPT tokens. So after a generation the
                    // cache physically holds K/V state for (prompt + generated tokens) while
                    // box.tokens claims just the prompt — a `overflow`-token tail the box
                    // doesn't know about. If left alone, the next keystroke's `.reuse` decision
                    // appends fresh deltaTokens on top of a cache still holding the PREVIOUS
                    // ghost text (and its trailing <end_of_turn>), and the model attends to
                    // phantom text it never generated for this turn — a wedged end-of-turn
                    // token is a near-deterministic "emit EOS now" signal, producing an empty
                    // completion. Trim the overflow (or invalidate if untrimmable) so
                    // box.tokens and the cache offset agree before `decide` runs. Doing this at
                    // the START of the call (rather than after streaming) is race-free —
                    // `container.perform` serializes — and also covers early-break/cancelled
                    // streams that advanced the cache without box.tokens ever being updated for
                    // the aborted turn.
                    if let existingCache = box.kvCache {
                        let cacheOffset = existingCache.first?.offset ?? 0
                        let overflow = PromptCacheValidity.cacheOverflow(
                            cacheOffset: cacheOffset, trackedTokenCount: box.tokens.count)
                        if overflow > 0 {
                            if canTrimPromptCache(existingCache) {
                                let trimmed = trimPromptCache(existingCache, numTokens: overflow)
                                signposter.emitEvent("cacheTrim", id: signpostID, "overflow=\(overflow) trimmed=\(trimmed)")
                                logger.info("cache trim: overflow=\(overflow, privacy: .public) trimmed=\(trimmed, privacy: .public)")
                            } else {
                                box.invalidate()
                                signposter.emitEvent("cacheTrimUnavailable", id: signpostID, "overflow=\(overflow)")
                                logger.info("cache trim unavailable (untrimmable cache type): overflow=\(overflow, privacy: .public), invalidating")
                            }
                        }
                    }

                    let newTokens = try context.tokenizer.applyChatTemplate(messages: messages)
                    let decision = PromptCacheValidity.decide(cachedTokens: box.tokens, newTokens: newTokens)

                    let inputTokens: [Int]
                    let cache: [KVCache]
                    switch decision {
                    case .reuse(let deltaTokens) where box.kvCache != nil:
                        inputTokens = deltaTokens
                        cache = box.kvCache!
                        logger.info("cache decision: reuse deltaTokens=\(deltaTokens.count, privacy: .public) totalTokens=\(newTokens.count, privacy: .public)")
                        signposter.emitEvent("cacheReuse", id: signpostID, "deltaTokens=\(deltaTokens.count) totalTokens=\(newTokens.count)")
                    case .reuse, .rebuild:
                        inputTokens = newTokens
                        cache = context.model.newCache(parameters: params)
                        logger.info("cache decision: rebuild totalTokens=\(newTokens.count, privacy: .public)")
                        signposter.emitEvent("cacheRebuild", id: signpostID, "totalTokens=\(newTokens.count)")
                    }

                    let lmInput = LMInput(tokens: MLXArray(inputTokens))
                    let generated = try MLXLMCommon.generate(
                        input: lmInput, cache: cache, parameters: params, context: context)

                    box.kvCache = cache
                    box.tokens = newTokens
                    return generated
                }

                signposter.endInterval("complete", interval)

                guard !Task.isCancelled else { return }

                var raw = ""
                var lastGhost = ""

                for await generation in stream {
                    if Task.isCancelled { break }
                    if case .chunk(let text) = generation {
                        raw += text
                        let ghost = InferenceEngine.ghostText(typed: prompt, raw: raw, isFillInMiddle: true, maxWords: maxWords, suffix: suffix)
                        if !ghost.isEmpty { lastGhost = ghost; onUpdate(ghost) }
                        // Early stop: the overlay only shows the first line (≤ maxWords), so once
                        // that's settled there's nothing more to display — stop generating to keep
                        // suggestions snappy and save battery instead of letting the model ramble.
                        if GhostText.shouldStopStreaming(raw: raw, maxWords: maxWords) { break }
                    }
                }

                logger.debug("generation result: raw='\(raw.prefix(120), privacy: .private)' -> ghost='\(lastGhost.prefix(80), privacy: .private)'")
            } catch {
                logger.error("generation error: \(error.localizedDescription, privacy: .public)")
            }

            if !Task.isCancelled { onComplete() }
        }
    }

    func cancelCurrent() {
        currentTask?.cancel()
    }

    // MARK: - Output → ghost text

    /// Delegates to `GhostText` (pure, testable). Kept as a thin wrapper so the
    /// streaming loop above reads naturally.
    nonisolated static func ghostText(typed: String, raw: String, isFillInMiddle: Bool = false, maxWords: Int = 0, suffix: String = "") -> String {
        GhostText.build(typed: typed, raw: raw, isFillInMiddle: isFillInMiddle, maxWords: maxWords, suffix: suffix)
    }
}
