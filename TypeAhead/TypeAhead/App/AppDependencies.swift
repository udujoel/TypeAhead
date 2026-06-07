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

    private var screenContextCache: (text: String, at: Date)?
    private let screenContextCacheTTL: TimeInterval = 2.0

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

        // Screen context: OCR the frontmost window to give the model ambient topic signal.
        // Cache for 2s so rapid keystrokes don't re-capture on every completion.
        let screenContext: String?
        if settings.useScreenshotContext {
            if let cache = screenContextCache, Date().timeIntervalSince(cache.at) < screenContextCacheTTL {
                screenContext = cache.text
            } else {
                let extracted = await ScreenshotContextProvider.captureAndExtractText()
                screenContext = extracted
                if let text = extracted { screenContextCache = (text, Date()) }
            }
        } else {
            screenContext = nil
            screenContextCache = nil
        }

        // Require a minimum typed prefix before firing. Check textBeforeCursor directly —
        // NOT the assembled prompt — so that screen context (which can be 120+ chars of OCR
        // text) doesn't inflate the count past the threshold when the user has only typed
        // 1-2 characters. 8 chars = one meaningful word + space.
        guard context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { return }

        let prompt = ContextBuilder.buildPrompt(
            context: context,
            clipboard: nil,
            history: [],
            customInstructions: settings.customInstructions,
            screenContext: screenContext
        )

        // Fill-in-middle context: only the AX path knows what's after the cursor.
        // The keystroke-buffer fallback has no suffix, so this stays empty there.
        let suffix = ContextBuilder.buildSuffix(context: context)

        // Personalization: build the system instruction note from custom instructions
        // + frequency-weighted history examples. Gate on `storeInputHistory` so that
        // disabling the "Collect inputs" toggle makes the history opt-out effective —
        // no already-recorded words continue to be injected when the user turns it off.
        let historyExamples: [String]
        if settings.storeInputHistory {
            historyExamples = await personalizationEngine.examples(
                strength: settings.personalizationStrength,
                limit: 5
            )
        } else {
            historyExamples = []
        }
        let personaNote = PersonalizationEngine.buildPersonaNote(
            customInstructions: settings.customInstructions,
            examples: historyExamples
        )

        guard let cursorRect = accessibilityManager.cursorScreenRect() else { return }
        let fontSize = accessibilityManager.focusedFontSize()
        print("⌨️ [\(source)] prompt='\(prompt.suffix(60))' suffix='\(suffix.prefix(40))' persona=\(personaNote != nil) cursor=\(cursorRect)")

        inferenceEngine.complete(
            prompt: prompt,
            suffix: suffix,
            maxTokens: settings.completionLength.maxTokens,
            maxWords: settings.completionLength.maxWords,
            personaNote: personaNote
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
