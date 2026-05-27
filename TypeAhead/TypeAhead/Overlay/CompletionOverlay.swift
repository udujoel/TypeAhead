import AppKit

@MainActor
final class CompletionOverlay {
    private let panel: NSPanel
    private let textField: NSTextField

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 32),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = NSColor(white: 0.12, alpha: 0.95)
        panel.isOpaque = false
        panel.hasShadow = true

        textField = NSTextField(frame: NSRect(x: 8, y: 4, width: 384, height: 24))
        textField.isEditable = false
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.textColor = NSColor.placeholderTextColor
        textField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        panel.contentView?.addSubview(textField)
    }

    func show(text: String, near cursorRect: NSRect) {
        textField.stringValue = text
        textField.sizeToFit()
        let panelWidth = min(textField.frame.width + 24, 500)
        let panelSize = NSSize(width: panelWidth, height: 32)
        let origin = OverlayPositioner.panelOrigin(cursorRect: cursorRect, panelSize: panelSize)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.06
            panel.animator().alphaValue = 1
        }
    }

    func update(text: String) {
        textField.stringValue = text
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
        })
    }

    var currentText: String {
        textField.stringValue
    }
}
