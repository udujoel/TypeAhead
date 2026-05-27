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

        deps.keyMonitor.onKeystroke = { [weak deps] _ in
            deps?.completionPipeline.keystrokeReceived()
        }
        deps.keyMonitor.onTabPressed = { [weak deps] in
            guard let deps else { return }
            let nextWord = deps.completionOverlay.currentText
                .split(separator: " ", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            if !nextWord.isEmpty, let element = deps.accessibilityManager.focusedElement() {
                deps.accessibilityManager.insertCompletion(nextWord + " ", into: element)
                Task { @MainActor in
                    try? await deps.historyStore.record(accepted: nextWord, appName: "")
                }
            }
            deps.inferenceEngine.cancelCurrent()
            deps.completionOverlay.hide()
        }
        deps.keyMonitor.onDismiss = { [weak deps] in
            deps?.inferenceEngine.cancelCurrent()
            deps?.completionOverlay.hide()
        }
        deps.keyMonitor.start()

        Task { @MainActor in
            let config = ModelConfig.recommended(availableRAMGB: Self.availableRAMGB())
            try? await deps.inferenceEngine.loadModel(config: config)
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
