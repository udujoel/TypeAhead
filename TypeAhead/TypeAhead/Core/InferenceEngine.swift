import Foundation
import MLXLLM
import MLXLMCommon

enum InferenceError: Error {
    case modelNotLoaded
    case loadFailed(String)
}

@MainActor
final class InferenceEngine {

    private(set) var isLoaded = false
    private var container: ModelContainer?
    private var currentTask: Task<Void, Never>?

    private static let systemPrompt = """
        You are a text completion engine embedded in a keyboard shortcut tool.
        RULES — follow exactly:
        - Output ONLY the completion text. No labels, no quotes, no explanations.
        - Complete with 1–8 words. Stop at a natural phrase boundary.
        - Match the register, style, and language of the input exactly.
        - Never echo back words that already appear at the end of the input.
        - If the text ends mid-word, complete that word first.
        """

    var isAvailable: Bool { isLoaded }
    var availabilityDescription: String { isLoaded ? "MLX model loaded" : "No model loaded" }

    // MARK: - Load / Unload

    func loadModel(
        config: ModelConfig,
        progressHandler: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        isLoaded = false
        container = nil
        let modelConfig = ModelConfiguration(id: config.huggingFaceRepo)
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfig
            ) { progress in
                Task { @MainActor in
                    progressHandler(progress.fractionCompleted)
                }
            }
            isLoaded = true
        } catch {
            throw InferenceError.loadFailed(error.localizedDescription)
        }
    }

    func unloadModel() {
        currentTask?.cancel()
        currentTask = nil
        container = nil
        isLoaded = false
    }

    // MARK: - Completion

    func complete(
        prompt: String,
        maxTokens: Int,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        currentTask?.cancel()
        guard isLoaded, let container else { onComplete(); return }

        currentTask = Task {
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.4)
            let session = ChatSession(
                container,
                instructions: InferenceEngine.systemPrompt,
                generateParameters: params
            )
            do {
                for try await token in session.streamResponse(to: prompt) {
                    if Task.isCancelled { break }
                    onToken(token)
                }
            } catch {
                // swallow generation errors — onComplete fires regardless
            }
            if !Task.isCancelled { onComplete() }
        }
    }

    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }
}
