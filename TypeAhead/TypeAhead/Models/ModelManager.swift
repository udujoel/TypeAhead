import Foundation
import Observation

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(Double)   // 0.0 – 1.0
    case loading
    case active

    static func == (lhs: ModelStatus, rhs: ModelStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded), (.loading, .loading), (.active, .active): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        default: return false
        }
    }
}

@Observable
@MainActor
final class ModelManager {

    private(set) var statuses: [String: ModelStatus] = [:]
    private let inferenceEngine: InferenceEngine
    private let settings: AppSettings

    init(inferenceEngine: InferenceEngine, settings: AppSettings) {
        self.inferenceEngine = inferenceEngine
        self.settings = settings
        refreshStatuses()
    }

    // MARK: - Status helpers

    func status(for config: ModelConfig) -> ModelStatus {
        statuses[config.id] ?? .notDownloaded
    }

    var activeModelStatus: ModelStatus {
        statuses[settings.activeModelID] ?? .notDownloaded
    }

    var isAnyModelActive: Bool {
        statuses.values.contains(.active)
    }

    // MARK: - Actions

    /// Downloads (if needed) and loads a model as the active inference engine.
    /// Streams progress from 0.0 → 1.0 through `.downloading`, then transitions to `.active`.
    func downloadAndActivate(config: ModelConfig) async {
        guard statuses[config.id] != .active else { return }
        statuses[config.id] = .downloading(0)

        do {
            try await inferenceEngine.loadModel(config: config) { [weak self] progress in
                Task { @MainActor [weak self] in
                    // Keep showing .downloading until fully loaded
                    if progress < 1.0 {
                        self?.statuses[config.id] = .downloading(progress)
                    } else {
                        self?.statuses[config.id] = .loading
                    }
                }
            }
            // Deactivate the previous model
            for id in statuses.keys where statuses[id] == .active {
                statuses[id] = .notDownloaded
            }
            statuses[config.id] = .active
            settings.activeModelID = config.id
        } catch {
            // Roll back to whatever the cached state is
            statuses[config.id] = Self.isModelCached(repoId: config.huggingFaceRepo)
                ? .notDownloaded
                : .notDownloaded
        }
    }

    // MARK: - Private

    private func refreshStatuses() {
        for config in ModelConfig.all {
            let cached = Self.isModelCached(repoId: config.huggingFaceRepo)
            let isActiveLoaded = config.id == settings.activeModelID && inferenceEngine.isLoaded
            statuses[config.id] = isActiveLoaded ? .active : (cached ? .notDownloaded : .notDownloaded)
        }
    }

    /// Checks whether a model's files exist in the HuggingFace local hub cache.
    /// No imports needed — the cache path follows a predictable naming convention.
    static func isModelCached(repoId: String) -> Bool {
        // "mlx-community/gemma-4-e2b-it-4bit" → "models--mlx-community--gemma-4-e2b-it-4bit"
        let dirName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/\(dirName)")
        return FileManager.default.fileExists(atPath: cacheURL.path)
    }
}
