import Foundation

@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    let settings = AppSettings()
    let accessibilityManager = AccessibilityManager()
    let inferenceEngine = InferenceEngine()
    let completionOverlay = CompletionOverlay()
    let historyStore = HistoryStore()
    lazy var personalizationEngine = PersonalizationEngine(historyStore: historyStore)
    lazy var completionPipeline: CompletionPipeline = CompletionPipeline(
        debounceInterval: settings.completionDelay,
        enabled: settings.completionsEnabled
    ) { [weak self] in
        await self?.runCompletion()
    }
    let keyMonitor = KeyEventMonitor()

    private func runCompletion() async {
        guard let context = accessibilityManager.readTextContext() else { return }
        let history = await historyStore.recentAcceptedPhrases(limit: 5)
        let clipboard = settings.useClipboardContext ? ClipboardContextProvider.current() : nil
        let prompt = ContextBuilder.buildPrompt(
            context: context,
            clipboard: clipboard,
            history: history,
            customInstructions: settings.customInstructions
        )
        var accumulated = ""
        let cursorRect = accessibilityManager.cursorScreenRect() ?? .zero
        inferenceEngine.complete(prompt: prompt, maxTokens: settings.completionLength.maxTokens) { [weak self] token in
            guard let self else { return }
            accumulated += token
            Task { @MainActor [weak self] in
                guard let self else { return }
                if accumulated.count == token.count {
                    completionOverlay.show(text: accumulated, near: cursorRect)
                } else {
                    completionOverlay.update(text: accumulated)
                }
            }
        } onComplete: {}
    }
}
