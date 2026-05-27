import Foundation

@MainActor
final class CompletionPipeline {
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    var isEnabled: Bool

    private(set) var inferenceCallCount = 0
    private let inferenceAction: @Sendable () async -> Void

    init(
        debounceInterval: TimeInterval = 0.12,
        enabled: Bool = true,
        inferenceAction: @escaping @Sendable () async -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.isEnabled = enabled
        self.inferenceAction = inferenceAction
    }

    func keystrokeReceived() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(debounceInterval))
            } catch { return }
            guard !Task.isCancelled else { return }
            await inferenceAction()
            self.inferenceCallCount += 1
        }
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    static func mock(debounceInterval: TimeInterval = 0.12, enabled: Bool = true) -> CompletionPipeline {
        CompletionPipeline(debounceInterval: debounceInterval, enabled: enabled, inferenceAction: {})
    }
}
