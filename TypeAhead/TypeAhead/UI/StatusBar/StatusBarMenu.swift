import AppKit
import Carbon
import os

/// The menu-bar status item — TypeAhead's primary control surface for an accessory (no-Dock) app.
///
/// The menu rebuilds itself every time it opens (via `NSMenuDelegate.menuNeedsUpdate`) so that
/// per-app state, the active model, and the accepted-completion count are always current. The
/// status-item button is hardened to stay visible even if its SF Symbol fails to load (otherwise
/// it renders as an invisible, un-clickable region and looks like the app "disappeared").
@MainActor
final class StatusBarMenu: NSObject, NSMenuDelegate {
    private let logger = Logger(subsystem: "app.typeahead", category: "StatusBarMenu")
    /// Recreated in place by `installStatusItem()` when the health check finds the backing
    /// WindowServer scene dead — see `verifyAndRecoverStatusItem()`.
    private var statusItem: NSStatusItem!
    private let settings: AppSettings
    private let pipeline: CompletionPipeline
    private let modelManager: ModelManager
    private let historyStore: HistoryStore

    /// When set to a future time, suggestions are snoozed until then (auto-resumes via `pauseTimer`).
    private var pausedUntil: Date?
    private var pauseTimer: Timer?
    /// Last-known accepted count, refreshed asynchronously whenever the menu opens.
    private var acceptedCount: Int = 0

    // MARK: - Status-item health recovery state

    private var recoveryTimer: Timer?
    private var consecutiveUnhealthyChecks = 0
    /// Guards the fallback-Settings breadcrumb so it only ever fires once per app run —
    /// repeated unhealthy checks would otherwise reopen Settings every 60s.
    private var hasOpenedFallbackSettings = false

    init(settings: AppSettings,
         pipeline: CompletionPipeline,
         modelManager: ModelManager,
         historyStore: HistoryStore) {
        self.settings = settings
        self.pipeline = pipeline
        self.modelManager = modelManager
        self.historyStore = historyStore
        super.init()
        installStatusItem()

        // Diagnostic so we can confirm from logs that THIS build's menu installed and is visible
        // (vs. a stale build, or the icon being hidden behind the notch / a crowded menu bar).
        let hasButton = statusItem.button != nil
        logger.info("StatusBarMenu installed — button=\(hasButton, privacy: .public) visible=\(self.statusItem.isVisible, privacy: .public) items=\(self.statusItem.menu?.items.count ?? 0, privacy: .public) (rich menu v3 + ^~T)")

        // After layout settles, report whether macOS actually placed the icon in a menu-bar
        // window. windowAttached=false with visible=true is the signature of notch/overflow
        // hiding — the icon exists but has no on-screen slot. The ⌃⌥⌘T shortcut covers that case.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let attached = self.isStatusItemHealthy()
            let w = Int(self.statusItem.button?.frame.width ?? 0)
            self.logger.info("StatusBarMenu post-launch — windowAttached=\(attached, privacy: .public) buttonWidth=\(w, privacy: .public) (if false: icon hidden by overflow — use ^~T)")
        }

        scheduleStatusItemHealthChecks()
    }

    /// Opens the full status menu at the current mouse location — the escape hatch for when the
    /// menu-bar icon is hidden behind the notch on a crowded menu bar. Wired to the global ⌃⌥⌘T
    /// shortcut. Builds a fresh menu so it never conflicts with the one owned by `statusItem`.
    func showMenuAtMouse() {
        // Build before activating: once TypeAhead is frontmost, the per-app and per-site items
        // can no longer see which app (and page) the user was in.
        let popup = NSMenu()
        rebuild(popup)
        NSApp.activate(ignoringOtherApps: true)
        popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - Status-item button (must never become invisible)

    /// Builds the `NSStatusItem` from scratch: allocates it from `NSStatusBar.system`,
    /// configures its button, and attaches a freshly-built menu. Shared by `init` and by
    /// `verifyAndRecoverStatusItem()` — the latter calls this after removing a dead item so
    /// recovery goes through exactly the same setup path as first launch.
    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()

        let menu = NSMenu()
        menu.delegate = self          // contents rebuilt on each open — always fresh
        rebuild(menu)                 // eager build: never show an empty menu if the delegate misfires
        statusItem.menu = menu
    }

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

    // MARK: - Status-item health check + recovery
    //
    // macOS can tear down the status item's backing WindowServer scene out from under us —
    // logs show `FBSSceneErrorDomain code 2 "scene-invalidated"` — while AppKit-side state
    // (`statusItem.button`, `statusItem.isVisible`) keeps reporting everything as fine. That
    // failure isn't directly observable from the app; the best available proxy is whether the
    // button's window is actually attached and on-screen, which is the same signal the
    // post-launch diagnostic probe above logs as `windowAttached`. This is best-effort: a
    // scene-dead item and a notch/overflow-hidden item can look identical from here, so an
    // unhealthy reading triggers a recreate either way (harmless if the item was just hidden,
    // not dead) and, if it doesn't stick, a one-time fallback to the Settings window.

    /// Schedules the recurring health check: once ~5s after launch (give layout time to
    /// settle) and then every 60s for the life of the app. Each check is two property reads
    /// when healthy — cheap enough to leave running indefinitely.
    private func scheduleStatusItemHealthChecks() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.verifyAndRecoverStatusItem()
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.verifyAndRecoverStatusItem() }
        }
    }

    /// Best-effort proxy for "is the status item actually on screen": the button must exist
    /// and its window must be attached and visible. See the health-check section note above
    /// for why this can't be more precise.
    private func isStatusItemHealthy() -> Bool {
        guard let window = statusItem.button?.window else { return false }
        return window.isVisible && window.windowNumber > 0
    }

    /// Runs one health check and acts on `StatusBarMenuLogic.statusItemRecoveryDecision`: an
    /// unhealthy item is torn down and rebuilt via `installStatusItem()`; if it's still
    /// unhealthy on the very next check (the recreate didn't stick), Settings is opened once
    /// per app run so the user always has a reachable surface.
    private func verifyAndRecoverStatusItem() {
        let decision = StatusBarMenuLogic.statusItemRecoveryDecision(
            isHealthy: isStatusItemHealthy(),
            previousConsecutiveUnhealthyChecks: consecutiveUnhealthyChecks,
            hasOpenedFallbackSettings: hasOpenedFallbackSettings)

        consecutiveUnhealthyChecks = decision.consecutiveUnhealthyChecks

        guard decision.shouldRecreate else { return }

        logger.info("status item scene dead — recreating (consecutive=\(self.consecutiveUnhealthyChecks, privacy: .public))")
        NSStatusBar.system.removeStatusItem(statusItem)
        installStatusItem()

        if decision.shouldOpenFallbackSettings {
            hasOpenedFallbackSettings = true
            logger.info("status item still unhealthy after recreate — opening Settings as a reachable fallback")
            SettingsWindowController.shared.open()
        }
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
        if let notice = StatusBarMenuLogic.secureInputNotice(isSecureInputOn: IsSecureEventInputEnabled()) {
            menu.addItem(disabledItem("⚠︎ " + notice))
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
            for option in StatusBarMenuLogic.SnoozeOption.allCases {
                let pauseItem = NSMenuItem(title: option.title,
                                           action: #selector(pause(_:)),
                                           keyEquivalent: "")
                pauseItem.target = self
                pauseItem.representedObject = option
                menu.addItem(pauseItem)
            }
        }

        // — Per-app on/off (only when a real foreground app is targetable) — reflects and edits
        // the same per-app override the Settings → Apps pane shows (A9).
        if let (appName, bundleID) = frontmostTargetApp() {
            let enabled = perAppEnabled(bundleID: bundleID)
            if let title = StatusBarMenuLogic.perAppItemTitle(appName: appName, isExcluded: !enabled) {
                menu.addItem(.separator())
                let appItem = NSMenuItem(title: title, action: #selector(toggleCurrentApp), keyEquivalent: "")
                appItem.target = self
                appItem.representedObject = bundleID
                menu.addItem(appItem)
            }
            // Per-website on/off when a browser is in front and its page address is readable.
            if SiteRules.isBrowser(bundleID: bundleID),
               let host = AppDependencies.shared.accessibilityManager.focusedWebHost(),
               let domain = SiteRules.matchingDomain(host: host, in: settings.siteRules.keys)
                   ?? SiteRules.normalizedDomain(host) {
                let siteEnabled = settings.siteRules[domain]?.completionsEnabled ?? enabled
                let siteItem = NSMenuItem(title: StatusBarMenuLogic.perSiteItemTitle(domain: domain, isEnabled: siteEnabled),
                                          action: #selector(toggleSite(_:)), keyEquivalent: "")
                siteItem.target = self
                siteItem.representedObject = [domain, siteEnabled ? "off" : "on"]
                menu.addItem(siteItem)
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

        // A8: no "Check for Updates…" item until Sparkle is actually linked — a permanently
        // greyed-out item is a control that does nothing.

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

    @objc private func pause(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? StatusBarMenuLogic.SnoozeOption else { return }
        let until = option.deadline(from: Date(), calendar: .current)
        pausedUntil = until
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resumeSuggestions() }
        }
        applyEnabledState()
    }

    @objc private func resumeSuggestions() {
        clearPause()
        applyEnabledState()
    }

    @objc private func toggleCurrentApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              let (name, _) = frontmostTargetApp() else { return }
        setPerApp(bundleID: bundleID, displayName: name, enabled: !perAppEnabled(bundleID: bundleID))
    }

    @objc private func toggleSite(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String], payload.count == 2 else { return }
        let turnOn = payload[1] == "on"
        settings.updateSiteRule(domain: payload[0]) { $0.completionsEnabled = turnOn }
        if !turnOn {
            AppDependencies.shared.overlayController.hide(animated: false)
            AppDependencies.shared.inferenceEngine.cancelCurrent()
        }
    }

    /// B3: the ⌃⌥⌘` shortcut — flip completions for whatever app is in front, with a brief HUD so
    /// the change is visible (there's no menu open to show it).
    func toggleFrontmostApp() {
        guard let (name, bundleID) = frontmostTargetApp() else { return }
        let enabled = !perAppEnabled(bundleID: bundleID)
        setPerApp(bundleID: bundleID, displayName: name, enabled: enabled)
        ToastHUD.show(enabled ? "Suggestions on in \(name)" : "Suggestions off in \(name)")
    }

    /// Whether the app is switched on in its own right (ignoring the global switch and snooze).
    private func perAppEnabled(bundleID: String) -> Bool {
        AppPolicyResolver.perAppCompletionsEnabled(
            excludedByList: settings.exceptionList.isExcluded(bundleID: bundleID),
            override: settings.appRegistry[bundleID]?.override
        )
    }

    private func setPerApp(bundleID: String, displayName: String, enabled: Bool) {
        settings.updateOverride(bundleID: bundleID, displayName: displayName) { $0.completionsEnabled = enabled }
        if !enabled {
            // Don't leave a ghost from this app on screen after switching it off.
            AppDependencies.shared.overlayController.hide(animated: false)
            AppDependencies.shared.inferenceEngine.cancelCurrent()
        }
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
