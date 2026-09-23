import AppKit

/// A brief, non-activating on-screen notice ("Suggestions off in Slack") for actions triggered
/// by a global shortcut, where no menu or window is open to show the result. Never takes focus,
/// ignores the mouse, and fades itself out.
@MainActor
enum ToastHUD {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, duration: TimeInterval = 1.4) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()

        let padding = NSSize(width: 20, height: 12)
        let size = NSSize(width: label.frame.width + padding.width * 2,
                          height: label.frame.height + padding.height * 2)

        let hud = panel ?? makePanel()
        panel = hud
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        label.frame.origin = NSPoint(x: padding.width, y: padding.height)
        background.addSubview(label)
        hud.contentView = background

        // Bottom-center of the screen with the mouse — where the user is looking.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.18)
        hud.setFrame(NSRect(origin: origin, size: size), display: true)
        hud.alphaValue = 1
        hud.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; hud.animator().alphaValue = 0 }, completionHandler: nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }
}
