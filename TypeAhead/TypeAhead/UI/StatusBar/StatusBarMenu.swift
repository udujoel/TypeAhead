import AppKit

/// The menu-bar status item — TypeAhead's primary control surface for an accessory (no-Dock) app.
///
/// The menu rebuilds itself every time it opens (via `NSMenuDelegate.menuNeedsUpdate`) so that
/// per-app state, the active model, and the accepted-completion count are always current. The
/// status-item button is hardened to stay visible even if its SF Symbol fails to load (otherwise
/// it renders as an invisible, un-clickable region and looks like the app "disappeared").
@MainActor
final class StatusBarMenu: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: AppSettings
    private let pipeline: CompletionPipeline
    private let modelManager: ModelManager
    private let historyStore: HistoryStore

    /// When set to a future time, suggestions are snoozed until then (auto-resumes via `pauseTimer`).
    private var pausedUntil: Date?
    private var pauseTimer: Timer?
    /// Last-known accepted count, refreshed asynchronously whenever the menu opens.
    private var acceptedCount: Int = 0

    init(settings: AppSettings,
         pipeline: CompletionPipeline,
         modelManager: ModelManager,
         historyStore: HistoryStore) {
        self.settings = settings
        self.pipeline = pipeline
        self.modelManager = modelManager
        self.historyStore = historyStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()

        let menu = NSMenu()
        menu.delegate = self          // contents rebuilt on each open — always fresh
        rebuild(menu)                 // eager build: never show an empty menu if the delegate misfires
        statusItem.menu = menu

        // Diagnostic so we can confirm from logs that THIS build's menu installed and is visible
        // (vs. a stale build, or the icon being hidden behind the notch / a crowded menu bar).
        let hasButton = statusItem.button != nil
        print("📊 StatusBarMenu installed — button=\(hasButton) visible=\(statusItem.isVisible) items=\(menu.items.count) (rich menu v3 + ⌃⌥⌘T)")

        // After layout settles, report whether macOS actually placed the icon in a menu-bar
        // window. windowAttached=false with visible=true is the signature of notch/overflow
        // hiding — the icon exists but has no on-screen slot. The ⌃⌥⌘T shortcut covers that case.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let attached = self.statusItem.button?.window != nil
            let w = Int(self.statusItem.button?.frame.width ?? 0)
            print("📊 StatusBarMenu post-launch — windowAttached=\(attached) buttonWidth=\(w) (if false: icon hidden by overflow — use ⌃⌥⌘T)")
        }
    }

    /// Opens the full status menu at the current mouse location — the escape hatch for when the
    /// menu-bar icon is hidden behind the notch on a crowded menu bar. Wired to the global ⌃⌥⌘T
    /// shortcut. Builds a fresh menu so it never conflicts with the one owned by `statusItem`.
    func showMenuAtMouse() {
        NSApp.activate(ignoringOtherApps: true)
        let popup = NSMenu()
        rebuild(popup)
        popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - Status-item button (must never become invisible)

    private func configureButton() {
        // Force-visible: without an explicit true here a previously-persisted hidden state
        // could keep the item off the menu bar.
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "text.badge.checkmark",
                               accessibilityDescription: "TypeAhead") {
            image.isTemplate = true   // tints correctly for light/dark menu bars
            button.image = image
        } else {
            // SF Symbol unavailable (older macOS / render failure) — guarantee a visible,
            // clickable label so the menu-bar item is never a zero-width invisible target.
            button.title = "TA"
        }
        button.toolTip = "TypeAhead — AI text completions"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
        // Refresh the accepted-completion count for the *next* open (async; can't block the menu).
        Task { @MainActor in
            self.acceptedCount = await historyStore.recordCount()
        }
    }

    // MARK: - Menu construction

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let paused = StatusBarMenuLogic.isPaused(pausedUntil: pausedUntil, now: Date())

        // — Status header (disabled, informational) —
        let activeModelName = ModelConfig.all.first { $0.id == settings.activeModelID }?.displayName ?? "No model"
        let isReady = modelManager.activeModelStatus == .active
        menu.addItem(disabledItem(StatusBarMenuLogic.statusLine(modelName: activeModelName, isReady: isReady)))
        if acceptedCount > 0 {
            menu.addItem(disabledItem("\(acceptedCount) completions accepted"))
        }

        menu.addItem(.separator())

        // — Suggestions on/off (checkmark idiom) —
        let toggleItem = NSMenuItem(title: "Suggestions",
                                    action: #selector(toggleCompletions),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = (settings.completionsEnabled && !paused) ? .on : .off
        menu.addItem(toggleItem)

        // — Snooze / resume —
        if paused, let until = pausedUntil {
            let resumeItem = NSMenuItem(title: "Resume Suggestions",
                                        action: #selector(resumeSuggestions),
                                        keyEquivalent: "")
            resumeItem.target = self
            menu.addItem(resumeItem)
            menu.addItem(disabledItem("Paused until \(Self.timeFormatter.string(from: until))"))
        } else if settings.completionsEnabled {
            let pauseItem = NSMenuItem(title: "Pause for 1 Hour",
                                       action: #selector(pauseForOneHour),
                                       keyEquivalent: "")
            pauseItem.target = self
            menu.addItem(pauseItem)
        }

        // — Per-app exclusion (only when a real foreground app is targetable) —
        if let (appName, bundleID) = frontmostTargetApp() {
            let excluded = settings.exceptionList.isExcluded(bundleID: bundleID)
            if let title = StatusBarMenuLogic.perAppItemTitle(appName: appName, isExcluded: excluded) {
                menu.addItem(.separator())
                let appItem = NSMenuItem(title: title, action: #selector(toggleCurrentApp), keyEquivalent: "")
                appItem.target = self
                appItem.representedObject = bundleID
                menu.addItem(appItem)
            }
        }

        menu.addItem(.separator())

        // — Completion length submenu —
        menu.addItem(lengthSubmenuItem())
        // — Model submenu —
        menu.addItem(modelSubmenuItem())

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // "Check for Updates" is wired to Sparkle once the framework is linked.
        let updateItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        updateItem.isEnabled = false
        menu.addItem(updateItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit TypeAhead",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func lengthSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Completion Length", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for length in CompletionLength.allCases {
            let item = NSMenuItem(title: length.displayName, action: #selector(selectLength(_:)), keyEquivalent: "")
            item.target = self
            item.state = (settings.completionLength == length) ? .on : .off
            item.representedObject = length.rawValue
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func modelSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for config in ModelConfig.all {
            let status = modelManager.status(for: config)
            let item = NSMenuItem(title: modelItemTitle(config, status: status),
                                  action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = config.id
            item.state = (settings.activeModelID == config.id && status == .active) ? .on : .off
            // Disable while a model is mid-download/mid-load so we don't stack activations.
            if case .downloading = status { item.isEnabled = false }
            if status == .loading { item.isEnabled = false }
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func modelItemTitle(_ config: ModelConfig, status: ModelStatus) -> String {
        switch status {
        case .active:                return config.displayName
        case .loading:               return "\(config.displayName) — loading…"
        case .downloading(let p):    return "\(config.displayName) — downloading \(Int(p * 100))%"
        case .notDownloaded:
            let cached = ModelManager.isModelCached(repoId: config.huggingFaceRepo)
            return cached ? config.displayName
                          : "\(config.displayName) — \(String(format: "%.1f", config.fileSizeGB)) GB download"
        }
    }

    // MARK: - Actions

    @objc private func toggleCompletions() {
        settings.completionsEnabled.toggle()
        clearPause()                 // a manual toggle cancels any active snooze
        applyEnabledState()
    }

    @objc private func pauseForOneHour() {
        pausedUntil = Date().addingTimeInterval(3600)
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resumeSuggestions() }
        }
        applyEnabledState()
    }

    @objc private func resumeSuggestions() {
        clearPause()
        applyEnabledState()
    }

    @objc private func toggleCurrentApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var list = settings.exceptionList
        if list.isExcluded(bundleID: bundleID) {
            list.remove(bundleID: bundleID)
        } else {
            list.add(bundleID: bundleID)
        }
        settings.exceptionList = list   // triggers the didSet persist
    }

    @objc private func selectLength(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let length = CompletionLength(rawValue: raw) else { return }
        settings.completionLength = length
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let config = ModelConfig.all.first(where: { $0.id == id }),
              settings.activeModelID != id || modelManager.status(for: config) != .active else { return }
        Task { @MainActor in await modelManager.downloadAndActivate(config: config) }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.open()
    }

    // MARK: - Helpers

    private func applyEnabledState() {
        pipeline.isEnabled = StatusBarMenuLogic.effectiveEnabled(
            userEnabled: settings.completionsEnabled, pausedUntil: pausedUntil, now: Date())
    }

    private func clearPause() {
        pausedUntil = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
    }

    /// The frontmost app's (name, bundleID) when it's a real target — nil when there's no
    /// foreground app or it's TypeAhead itself (excluding our own app would be meaningless).
    private func frontmostTargetApp() -> (name: String, bundleID: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let name = app.localizedName, !name.isEmpty else { return nil }
        return (name, bundleID)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
