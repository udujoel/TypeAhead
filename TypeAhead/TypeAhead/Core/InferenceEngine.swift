import Foundation
import os
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

@MainActor
final class InferenceEngine {

    private(set) var isLoaded = false
    private var container: ModelContainer?
    private var currentTask: Task<Void, Never>?
    private var loadedModelID: String = ""
    private var lastLoggedLoadPct = -1

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
        print("⏳ loadModel: \(config.id) [\(config.huggingFaceRepo)] cached=\(cached) — starting")

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
            print("✅ loadModel: \(config.id) ready in \(Int(-start.timeIntervalSinceNow))s")
        } catch {
            print("❌ loadModel: \(config.id) failed after \(Int(-start.timeIntervalSinceNow))s: \(error)")
            throw InferenceError.loadFailed(error.localizedDescription)
        }
    }

    /// Logs load/download progress at most once per 10% so a stalled load is visible
    /// (e.g. "stuck at 100% → it's the model load/tokenizer, not the download").
    private func logLoadProgress(_ fraction: Double) {
        let pct = Int(fraction * 100)
        if pct >= lastLoggedLoadPct + 10 || pct >= 100 {
            lastLoggedLoadPct = pct
            print("📥 loadModel progress: \(pct)%")
        }
    }

    func unloadModel() {
        currentTask?.cancel()
        currentTask = nil
        container = nil
        isLoaded = false
        loadedModelID = ""
    }

    // MARK: - Completion

    /// Generates a completion for `prompt`. `onUpdate` receives the full cleaned
    /// completion text as it grows (call it to refresh the ghost-text overlay).
    /// `onComplete` fires once when generation finishes — unless superseded.
    ///
    /// - Parameter personaNote: Optional persona/style note from PersonalizationEngine
    ///   (customInstructions + frequent history words). Prepended to the base instruction.
    func complete(
        prompt: String,
        suffix: String = "",
        maxTokens: Int,
        maxWords: Int = 0,
        personaNote: String? = nil,
        onUpdate: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard isLoaded, let container else { onComplete(); return }

        currentTask?.cancel()

        let instruction = PersonalizationEngine.buildInstruction(personaNote: personaNote)

        // ASSISTANT-PREFILL (assembled in HFBridge): the model turn is seeded with `prompt`
        // and left open, so the instruct model continues the user's own text in-distribution.
        // Raw text made it loop; chat-replying made it ignore the text. The model emits only
        // NEW tokens, so the output IS the continuation — ghostText skips prefix-alignment.
        currentTask = Task {
            do {
                let userInput = UserInput(prompt: .chat([
                    Chat.Message.system(instruction),
                    Chat.Message.user(prompt),
                ]))

                // container.prepare(input:) uses Swift's `consuming sending` ownership
                // transfer to safely move the non-Sendable LMInput across actor boundaries.
                let input = try await container.prepare(input: userInput)

                guard !Task.isCancelled else { return }

                // No repetitionPenalty: it penalizes prompt tokens too, which pushed the
                // model toward newline/whitespace output. The maxWords cap handles visible
                // rambling instead. Slightly higher temperature gives real words a better
                // chance over a deterministic newline on short, ambiguous prefixes.
                let params = GenerateParameters(
                    maxTokens: maxTokens,
                    temperature: 0.5,
                    topP: 0.9
                )

                let stream = try await container.generate(input: input, parameters: params)
                var raw = ""

                for await generation in stream {
                    if Task.isCancelled { break }
                    if case .chunk(let text) = generation {
                        raw += text
                        let ghost = InferenceEngine.ghostText(typed: prompt, raw: raw, isFillInMiddle: true, maxWords: maxWords)
                        if !ghost.isEmpty { onUpdate(ghost) }
                    }
                }

                print("🧠 raw='\(raw.prefix(120))' → ghost='\(InferenceEngine.ghostText(typed: prompt, raw: raw, isFillInMiddle: true, maxWords: maxWords).prefix(80))'")
            } catch {
                print("⚠️ InferenceEngine: generation error: \(error)")
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
    nonisolated static func ghostText(typed: String, raw: String, isFillInMiddle: Bool = false, maxWords: Int = 0) -> String {
        GhostText.build(typed: typed, raw: raw, isFillInMiddle: isFillInMiddle, maxWords: maxWords)
    }
}
