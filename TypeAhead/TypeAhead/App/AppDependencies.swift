import AppKit

@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    let settings = AppSettings()
    let accessibilityManager = AccessibilityManager()
    let inferenceEngine = InferenceEngine()
    let completionOverlay = CompletionOverlay()
    let historyStore = HistoryStore()
    lazy var modelManager = ModelManager(inferenceEngine: inferenceEngine, settings: settings)
    lazy var personalizationEngine = PersonalizationEngine(historyStore: historyStore)
    lazy var completionPipeline: CompletionPipeline = CompletionPipeline(
        debounceInterval: settings.completionDelay,
        enabled: settings.completionsEnabled
    ) { [weak self] in
        await self?.runCompletion()
    }
    let keyMonitor = KeyEventMonitor()

    private func runCompletion() async {
        guard inferenceEngine.isLoaded else { return }

        // Read the text around the cursor. Prefer the Accessibility API (full
        // field contents); fall back to the keystroke buffer for apps where AX
        // is unavailable (e.g. some Electron apps).
        let context: TextContext
        let source: String
        if let axContext = accessibilityManager.readTextContext() {
            context = axContext
            source = "AX"
        } else {
            let bufferText = keyMonitor.keystrokeBuffer.text
            guard bufferText.count >= 3 else { return }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            context = TextContext(textBeforeCursor: bufferText, textAfterCursor: "", appName: appName, windowTitle: "")
            source = "buffer"
        }

        let prompt = ContextBuilder.buildPrompt(
            context: context,
            clipboard: nil,
            history: [],
            customInstructions: settings.customInstructions
        )
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }

        // Fill-in-middle context: only the AX path knows what's after the cursor.
        // The keystroke-buffer fallback has no suffix, so this stays empty there.
        let suffix = ContextBuilder.buildSuffix(context: context)

        guard let cursorRect = accessibilityManager.cursorScreenRect() else { return }
        let fontSize = accessibilityManager.focusedFontSize()
        print("⌨️ [\(source)] prompt='\(prompt.suffix(60))' suffix='\(suffix.prefix(40))' cursor=\(cursorRect)")

        inferenceEngine.complete(
            prompt: prompt,
            suffix: suffix,
            maxTokens: settings.completionLength.maxTokens,
            maxWords: settings.completionLength.maxWords
        ) { [weak self] full in
            // Called on the model executor — hop to main to touch UI.
            Task { @MainActor [weak self] in
                guard let self, !full.isEmpty else { return }
                if keyMonitor.isOverlayVisible, !completionOverlay.currentText.isEmpty {
                    completionOverlay.update(text: full, near: cursorRect)
                } else {
                    print("👻 overlay.show '\(full.prefix(40))' at \(cursorRect.origin)")
                    completionOverlay.show(text: full, near: cursorRect, fontSize: fontSize)
                    keyMonitor.isOverlayVisible = true
                }
            }
        } onComplete: {}
    }
}
