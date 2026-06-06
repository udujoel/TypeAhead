import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarMenu: StatusBarMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbuffered stdout so print() logs appear immediately when launched via `open`
        // with redirected output (LaunchServices launch → otherwise block-buffered).
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.setActivationPolicy(.accessory)
        let deps = AppDependencies.shared
        statusBarMenu = StatusBarMenu(
            settings: deps.settings,
            pipeline: deps.completionPipeline
        )

        // Keystroke handling with "type-through": if the user types the next character of
        // the current suggestion, advance the ghost and keep it shown (don't regenerate).
        // Only when they diverge do we clear and request a fresh completion.
        deps.keyMonitor.onKeystroke = { [weak deps] event in
            guard let deps else { return }
            let ghost = deps.completionOverlay.currentText
            if deps.keyMonitor.isOverlayVisible, !ghost.isEmpty,
               let typed = event.characters, typed.count == 1, ghost.hasPrefix(typed) {
                let remaining = String(ghost.dropFirst())
                if remaining.isEmpty {
                    deps.keyMonitor.isOverlayVisible = false
                    deps.completionOverlay.hide(animated: false)
                } else if let rect = deps.accessibilityManager.cursorScreenRect() {
                    deps.completionOverlay.update(text: remaining, near: rect)
                }
                return  // typed along with the suggestion — keep it, no regeneration
            }
            // Diverged (or nothing showing): clear and queue a fresh completion.
            deps.keyMonitor.isOverlayVisible = false
            deps.inferenceEngine.cancelCurrent()
            deps.completionOverlay.hide(animated: false)
            deps.completionPipeline.keystrokeReceived()
        }

        // Tab — accept the next word, then KEEP the remaining words showing so another Tab
        // accepts the next one. The suggestion persists (no regeneration) until the user
        // types something that diverges from it.
        deps.keyMonitor.onTabPressed = { [weak deps] in
            guard let deps else { return }
            let ghost = deps.completionOverlay.currentText
            let parts = ghost.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let firstWord = parts.first.map(String.init), !firstWord.isEmpty else {
                deps.keyMonitor.isOverlayVisible = false
                deps.completionOverlay.hide()
                return
            }

            let injection = firstWord + " "
            if let element = deps.accessibilityManager.focusedElement() {
                deps.accessibilityManager.insertCompletion(injection, into: element)
            } else {
                deps.accessibilityManager.injectText(injection)
            }
            deps.keyMonitor.keystrokeBuffer.appendAccepted(injection)
            Task { @MainActor in try? deps.historyStore.record(accepted: firstWord, appName: "") }

            // Keep the rest of the suggestion visible for the next Tab.
            let remaining = parts.count > 1 ? String(parts[1]) : ""
            if remaining.isEmpty {
                deps.keyMonitor.isOverlayVisible = false
                deps.completionOverlay.hide()
            } else if let rect = deps.accessibilityManager.cursorScreenRect() {
                deps.completionOverlay.update(text: remaining, near: rect)
                deps.keyMonitor.isOverlayVisible = true
            }
        }

        deps.keyMonitor.onDismiss = { [weak deps] in
            deps?.keyMonitor.isOverlayVisible = false
            deps?.inferenceEngine.cancelCurrent()
            deps?.completionOverlay.hide(animated: true)  // gentle fade on Escape
        }

        deps.keyMonitor.start()

        // One-time checks. If trusted is false → re-grant in System Settings. If a debugger
        // is attached, cross-process AX reads are DENIED (error -25204) regardless of trust,
        // so ghost text can't find the caret — the app must be launched standalone, not Cmd+R.
        print("🔐 Accessibility trusted: \(deps.accessibilityManager.isProcessTrusted)")
        print("🔬 Debugger attached: \(deps.accessibilityManager.isBeingDebugged) (if true, AX reads will fail — launch the app from Finder, not Xcode Run)")

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
