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

    /// Monotonic counter that changes on ANY event that invalidates the "current" generation
    /// cycle — both a fresh debounce/max-wait `fire()` AND a correction-key `cancel()` (backspace/
    /// arrows — see `AppDelegate.onKeystroke`). Distinct from `inferenceCallCount` (which counts
    /// only *actual* inference calls): `cancel()` doesn't start a new inference call, but it DOES
    /// mean any `onUpdate`/`onComplete` callback still in flight from the cycle that was running
    /// when the correction key landed must not paint or retry.
    ///
    /// WP-2 "heelp" bug: a backspace hides the overlay (`OverlayController.handleKeystroke`
    /// diverges) and calls `cancel()`, but `cancel()` only stops a *pending debounce* — it does
    /// NOT cancel an already in-flight `InferenceEngine.complete` task, and even when
    /// `inferenceCallCount == inferenceCallCount` still held afterwards, `onUpdate`'s Task had
    /// already been scheduled onto the main actor and executes anyway once it gets its turn. Since
    /// `keystrokeReceived()` (which DOES bump `inferenceCallCount`) is deliberately NOT called for
    /// correction keys, `inferenceCallCount` alone can't detect this case — this second counter
    /// closes that gap.
    private(set) var cycleValidityToken = 0

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
        cycleValidityToken += 1
        let action = inferenceAction
        Task { await action() }
    }

    /// Cancels a pending debounce (correction keys — see `AppDelegate.onKeystroke`'s
    /// `correctionKeyCodes` branch). Bumps `cycleValidityToken` unconditionally, whether or not a
    /// debounce was actually pending: a correction key always means "whatever generation cycle was
    /// running is no longer relevant to what's on screen," even if that cycle is already past the
    /// debounce stage and mid-inference (`cancel()` can't reach into `InferenceEngine` to stop it —
    /// see `cycleValidityToken`'s doc comment).
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        cycleValidityToken += 1
    }

    static func mock(
        debounceInterval: TimeInterval = 0.18,
        maxWait: TimeInterval = 0.5,
        enabled: Bool = true
    ) -> CompletionPipeline {
        CompletionPipeline(debounceInterval: debounceInterval, maxWait: maxWait, enabled: enabled, inferenceAction: {})
    }
}
