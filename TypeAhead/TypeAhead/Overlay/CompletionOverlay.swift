import AppKit

@MainActor
final class CompletionOverlay {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        label = NSTextField(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.textColor = NSColor.tertiaryLabelColor
        panel.contentView?.addSubview(label)
    }

    // MARK: - Show / Update / Hide

    func show(text: String, near cursorRect: NSRect, fontSize: CGFloat) {
        label.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        label.stringValue = text
        label.sizeToFit()
        repositionPanel(cursorRect: cursorRect)
        panel.alphaValue = 1
        panel.orderFront(nil)
    }

    func update(text: String, near cursorRect: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        repositionPanel(cursorRect: cursorRect)
    }

    /// - Parameter animated: Pass `false` on keystroke for an instant hide (no flicker).
    ///   Pass `true` for a gentle fade on explicit dismiss (Escape, timeout).
    func hide(animated: Bool = true) {
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: {
                self.panel.orderOut(nil)
            })
        } else {
            panel.alphaValue = 0
            panel.orderOut(nil)
        }
    }

    var currentText: String { label.stringValue }

    // MARK: - Private

    private func repositionPanel(cursorRect: NSRect) {
        // Size the panel to the label's natural line height (set by sizeToFit in show/update)
        // and anchor its bottom at the caret glyph's bottom. Because an NSTextField's baseline
        // sits ~one descender above its bottom — same as the text view's own glyphs — the
        // ghost baseline then coincides with the input baseline (no magic vertical fudge).
        let panelWidth = min(label.frame.width + 6, 600)
        let panelHeight = label.frame.height
        let panelSize = NSSize(width: panelWidth, height: panelHeight)
        let origin = OverlayPositioner.inlineOrigin(cursorRect: cursorRect, panelSize: panelSize)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        label.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
    }
}
