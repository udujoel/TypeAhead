import Foundation

/// Decides *when* to ask for a completion as the user types.
///
/// Pure debounce only fires after a pause, so suggestions never appear during sustained
/// typing. This adds a **max-wait**: debounce for the snappy trailing update, but if it's
/// been longer than `maxWait` since the last fire, fire immediately — so a fresh suggestion
/// shows up mid-burst too. Overlapping fires are harmless: each `inferenceAction` cancels the
/// previous in-flight generation.
@MainActor
final class CompletionPipeline {
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private let maxWait: TimeInterval
    private var lastFire: Date = .distantPast
    var isEnabled: Bool

    private(set) var inferenceCallCount = 0
    private let inferenceAction: @Sendable () async -> Void

    init(
        debounceInterval: TimeInterval = 0.18,
        maxWait: TimeInterval = 0.5,
        enabled: Bool = true,
        inferenceAction: @escaping @Sendable () async -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.maxWait = maxWait
        self.isEnabled = enabled
        self.inferenceAction = inferenceAction
    }

    func keystrokeReceived() {
        guard isEnabled else { return }
        debounceTask?.cancel()

        // Sustained typing: if we haven't fired in a while, fire now so a suggestion appears
        // while typing rather than only after a pause.
        if Date().timeIntervalSince(lastFire) >= maxWait {
            fire()
            return
        }

        // Otherwise debounce: fire shortly after the user pauses.
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(debounceInterval))
            } catch { return }
            guard !Task.isCancelled else { return }
            self.fire()
        }
    }

    private func fire() {
        lastFire = Date()
        inferenceCallCount += 1
        let action = inferenceAction
        Task { await action() }
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    static func mock(
        debounceInterval: TimeInterval = 0.18,
        maxWait: TimeInterval = 0.5,
        enabled: Bool = true
    ) -> CompletionPipeline {
        CompletionPipeline(debounceInterval: debounceInterval, maxWait: maxWait, enabled: enabled, inferenceAction: {})
    }
}
