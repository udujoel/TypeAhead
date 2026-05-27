import AppKit
import Sparkle

@MainActor
final class StatusBarMenu {
    private let statusItem: NSStatusItem
    private let settings: AppSettings
    private let pipeline: CompletionPipeline
    private let updaterController: SPUStandardUpdaterController

    init(settings: AppSettings, pipeline: CompletionPipeline, updaterController: SPUStandardUpdaterController) {
        self.settings = settings
        self.pipeline = pipeline
        self.updaterController = updaterController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "TypeAhead")
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: settings.completionsEnabled ? "Completions: On" : "Completions: Off",
            action: #selector(toggleCompletions),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let activeModel = ModelConfig.all.first { $0.id == settings.activeModelID }?.displayName ?? "Unknown"
        menu.addItem(NSMenuItem(title: "Model: \(activeModel)", action: nil, keyEquivalent: ""))

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TypeAhead", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleCompletions() {
        settings.completionsEnabled.toggle()
        pipeline.isEnabled = settings.completionsEnabled
        buildMenu()
    }

    @objc private func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
