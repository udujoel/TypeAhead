import Foundation
import MLX

// MARK: - InferenceEngine
//
// Uses the mlx-swift package (MLX) for on-device inference.
//
// NOTE: The mlx-swift-examples package no longer exports MLXLLM as a
// standalone importable library. Until a proper MLXLLM wrapper is available,
// loadModel() reads the model directory and marks the engine as ready, but
// generate() produces no tokens (stub). The menu bar, settings UI, keyboard
// monitoring, and overlay all work correctly while this stub is in place.
// Wire up real generation here once an MLXLLM-style API is available.

enum InferenceError: Error {
    case modelNotLoaded
    case inferenceTimeout
}

@MainActor
final class InferenceEngine {

    // Whether a model has been loaded from disk
    private(set) var isLoaded = false

    private var currentTask: Task<Void, Never>?

    private let modelDirectory: URL

    init() {
        modelDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeAhead/Models")
    }

    // MARK: - Load / Unload

    func loadModel(config: ModelConfig) async throws {
        let modelURL = modelDirectory.appendingPathComponent(config.id)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw InferenceError.modelNotLoaded
        }
        // TODO: replace with real MLXLLM weight loading once available
        isLoaded = true
    }

    func unloadModel() {
        currentTask?.cancel()
        currentTask = nil
        isLoaded = false
        // Free any GPU memory that MLX has cached
        GPU.clearCache()
    }

    // MARK: - Completion

    /// Streams generated tokens into `onToken`, then calls `onComplete`.
    /// Currently a stub — produces no tokens until the MLXLLM layer is wired up.
    func complete(
        prompt: String,
        maxTokens: Int,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        currentTask?.cancel()
        guard isLoaded else {
            onComplete()
            return
        }
        currentTask = Task {
            // TODO: run real MLX forward pass here, calling onToken for each token
            if !Task.isCancelled {
                onComplete()
            }
        }
    }

    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }
}
