import AppKit
import SwiftUI

/// Opens the settings UI in a plain NSWindow so we never need to call
/// `showSettingsWindow:`, which macOS 14+ restricts to SettingsLink only.
@MainActor
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private init() {
        let deps = AppDependencies.shared
        let rootView = SettingsWindow()
            .environment(deps.settings)
            .environment(deps.modelManager)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "TypeAhead Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 460))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func open() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
