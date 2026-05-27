import Foundation
import MLX
import MLXLLM

enum InferenceError: Error {
    case modelNotLoaded
    case inferenceTimeout
}

@MainActor
final class InferenceEngine {
    private var llmContainer: ModelContainer?
    private var currentTask: Task<Void, Never>?
    private let modelDirectory: URL

    init() {
        modelDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeAhead/Models")
    }

    func loadModel(config: ModelConfig) async throws {
        let modelURL = modelDirectory.appendingPathComponent(config.id)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw InferenceError.modelNotLoaded
        }
        let modelConfig = ModelConfiguration(directory: modelURL)
        llmContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig)
    }

    func unloadModel() {
        llmContainer = nil
        MLX.GPU.clearCache()
    }

    func complete(
        prompt: String,
        maxTokens: Int,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        currentTask?.cancel()
        guard let container = llmContainer else {
            onComplete()
            return
        }
        currentTask = Task {
            var count = 0
            let generateParameters = GenerateParameters(temperature: 0.3)
            let result = try? await container.perform { model, tokenizer in
                let promptTokens = tokenizer.encode(text: prompt)
                return TokenIterator(
                    model: model,
                    tokenizer: tokenizer,
                    tokens: promptTokens,
                    parameters: generateParameters
                )
            }
            guard let tokens = result else {
                onComplete()
                return
            }
            for token in tokens {
                if Task.isCancelled { break }
                onToken(token)
                count += 1
                if count >= maxTokens { break }
            }
            if !Task.isCancelled { onComplete() }
        }
    }

    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }
}
