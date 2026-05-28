import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarMenu: StatusBarMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let deps = AppDependencies.shared
        statusBarMenu = StatusBarMenu(
            settings: deps.settings,
            pipeline: deps.completionPipeline
        )

        // Any keystroke hides the current overlay and queues a new completion.
        deps.keyMonitor.onKeystroke = { [weak deps] _ in
            deps?.keyMonitor.isOverlayVisible = false
            deps?.inferenceEngine.cancelCurrent()
            deps?.completionOverlay.hide(animated: false)  // instant — no stale text flicker
            deps?.completionPipeline.keystrokeReceived()
        }

        // Tab (or Shift-Tab for word-by-word) — accept the next word of the completion.
        deps.keyMonitor.onTabPressed = { [weak deps] in
            guard let deps else { return }
            deps.keyMonitor.isOverlayVisible = false

            let nextWord = deps.completionOverlay.currentText
                .split(separator: " ", maxSplits: 1)
                .first
                .map(String.init) ?? ""

            if !nextWord.isEmpty {
                let injection = nextWord + " "

                // Try Accessibility injection (precise — replaces selection).
                // Fall back to CGEvent injection (types the characters directly).
                if let element = deps.accessibilityManager.focusedElement() {
                    deps.accessibilityManager.insertCompletion(injection, into: element)
                } else {
                    deps.accessibilityManager.injectText(injection)
                }

                // Keep the keystroke buffer consistent with what was accepted.
                deps.keyMonitor.keystrokeBuffer.appendAccepted(injection)

                Task { @MainActor in
                    try? deps.historyStore.record(accepted: nextWord, appName: "")
                }
            }

            deps.inferenceEngine.cancelCurrent()
            deps.completionOverlay.hide()
        }

        deps.keyMonitor.onDismiss = { [weak deps] in
            deps?.keyMonitor.isOverlayVisible = false
            deps?.inferenceEngine.cancelCurrent()
            deps?.completionOverlay.hide(animated: true)  // gentle fade on Escape
        }

        deps.keyMonitor.start()

        // Load (and download if needed) the user's chosen model on startup.
        // ModelManager streams progress into its statuses dict, which the UI observes.
        Task { @MainActor in
            let config = ModelConfig.all.first { $0.id == deps.settings.activeModelID }
                ?? ModelConfig.recommended(availableRAMGB: Self.availableRAMGB())
            await deps.modelManager.downloadAndActivate(config: config)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let deps = AppDependencies.shared
        deps.keyMonitor.stop()
        deps.inferenceEngine.unloadModel()
    }

    private static func availableRAMGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
}
