import Foundation
import Observation

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(Double)
    case downloaded
    case loading
    case active

    static func == (lhs: ModelStatus, rhs: ModelStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded), (.downloaded, .downloaded),
             (.loading, .loading), (.active, .active): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        default: return false
        }
    }
}

@Observable
@MainActor
final class ModelManager {
    private(set) var statuses: [String: ModelStatus] = [:]
    private var downloaders: [String: ModelDownloader] = [:]
    private let inferenceEngine: InferenceEngine
    private let settings: AppSettings

    init(inferenceEngine: InferenceEngine, settings: AppSettings) {
        self.inferenceEngine = inferenceEngine
        self.settings = settings
        for config in ModelConfig.all {
            statuses[config.id] = ModelDownloader(config: config).isDownloaded ? .downloaded : .notDownloaded
        }
    }

    func download(config: ModelConfig) async {
        let downloader = ModelDownloader(config: config)
        downloaders[config.id] = downloader
        statuses[config.id] = .downloading(0)
        do {
            try await downloader.start()
            statuses[config.id] = .downloaded
        } catch {
            statuses[config.id] = .notDownloaded
        }
    }

    func activate(config: ModelConfig) async {
        guard statuses[config.id] == .downloaded else { return }
        statuses[config.id] = .loading
        do {
            inferenceEngine.unloadModel()
            try await inferenceEngine.loadModel(config: config)
            for id in statuses.keys where statuses[id] == .active {
                statuses[id] = .downloaded
            }
            statuses[config.id] = .active
            settings.activeModelID = config.id
        } catch {
            statuses[config.id] = .downloaded
        }
    }

    func status(for config: ModelConfig) -> ModelStatus {
        if let downloader = downloaders[config.id], case .downloading = statuses[config.id] {
            return .downloading(downloader.progress)
        }
        return statuses[config.id] ?? .notDownloaded
    }
}
