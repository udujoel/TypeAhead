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
    /// If the model is already cached on disk, goes straight to `.loading` (no download bar).
    /// Otherwise streams `.downloading` progress from 0.0 → 1.0, then `.loading`, then `.active`.
    func downloadAndActivate(config: ModelConfig) async {
        guard statuses[config.id] != .active else { return }

        let isCached = ModelManager.isModelCached(repoId: config.huggingFaceRepo)
        statuses[config.id] = isCached ? .loading : .downloading(0)

        do {
            try await inferenceEngine.loadModel(config: config) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Only update progress bar during actual network download
                    if !isCached {
                        self.statuses[config.id] = progress < 1.0 ? .downloading(progress) : .loading
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
            print("❌ ModelManager.downloadAndActivate failed for \(config.id): \(error)")
            statuses[config.id] = .notDownloaded
        }
    }

    // MARK: - Private

    private func refreshStatuses() {
        for config in ModelConfig.all {
            let isActiveLoaded = config.id == settings.activeModelID && inferenceEngine.isLoaded
            statuses[config.id] = isActiveLoaded ? .active : .notDownloaded
        }
    }

    /// Checks whether a model's files exist in the Swift Hub cache (~/Library/Caches/models/{repoId}/).
    /// This is where MLXLLM's defaultHubApi downloads and reads models from.
    static func isModelCached(repoId: String) -> Bool {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelURL = cachesURL.appendingPathComponent("models/\(repoId)")
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelURL.path) else {
            return false
        }
        // At minimum the model needs a config.json and at least one weight file
        return contents.contains("config.json") && contents.contains(where: { $0.hasSuffix(".safetensors") })
    }
}
