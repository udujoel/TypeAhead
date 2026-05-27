import AppKit

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

    // Accumulates streamed tokens on the main actor
    private var currentCompletion = ""

    private func runCompletion() async {
        print("🔵 runCompletion called — isLoaded=\(inferenceEngine.isLoaded)")

        // Try AX first; fall back to keystroke buffer if AX isn't trusted yet.
        let context: TextContext
        if let axContext = accessibilityManager.readTextContext() {
            print("🟢 context via AX: app=\(axContext.appName), before='\(axContext.textBeforeCursor.suffix(40))'")
            context = axContext
        } else {
            let bufferText = keyMonitor.keystrokeBuffer.text
            guard bufferText.count >= 8 else {
                print("🔴 context too short — re-grant Accessibility in System Settings")
                return
            }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            context = TextContext(textBeforeCursor: bufferText, textAfterCursor: "", appName: appName, windowTitle: "")
            print("🟡 context via keystroke buffer: '\(bufferText.suffix(40))'")
        }

        let history = await historyStore.recentAcceptedPhrases(limit: 5)
        let clipboard = settings.useClipboardContext ? ClipboardContextProvider.current() : nil
        let prompt = ContextBuilder.buildPrompt(
            context: context,
            clipboard: clipboard,
            history: history,
            customInstructions: settings.customInstructions
        )
        currentCompletion = ""

        guard let cursorRect = accessibilityManager.cursorScreenRect() else { return }
        let fontSize = accessibilityManager.focusedFontSize()
        print("🟡 inferenceEngine.complete — prompt length=\(prompt.count), cursor=\(cursorRect)")

        inferenceEngine.complete(
            prompt: prompt,
            maxTokens: settings.completionLength.maxTokens
        ) { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isFirstToken = currentCompletion.isEmpty
                currentCompletion += token
                print("🟣 token: '\(token)'")
                if isFirstToken {
                    completionOverlay.show(text: currentCompletion, near: cursorRect, fontSize: fontSize)
                    keyMonitor.isOverlayVisible = true
                } else {
                    completionOverlay.update(text: currentCompletion, near: cursorRect)
                }
            }
        } onComplete: {
            print("✅ onComplete fired")
        }
    }
}
