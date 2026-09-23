import AppKit

/// The small numbered list shown by ⌥↓ (word alternatives): "1 memo   2 summary   3 notes",
/// just below the caret. Non-activating and mouse-transparent like the ghost overlay — choices are
/// made with the number keys, which `KeyEventMonitor` routes while `isVisible`.
@MainActor
final class AlternativesPanel {
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }()

    private(set) var isVisible = false
    private(set) var words: [String] = []

    /// Shows (or updates in place) the list under `caretRect` (Cocoa screen coordinates). An empty
    /// `words` list shows a quiet "Finding alternatives…" placeholder while samples arrive.
    func show(words: [String], below caretRect: NSRect) {
        self.words = words
        let text = words.isEmpty
            ? "Finding alternatives…"
            : words.enumerated().map { "\($0.offset + 1)  \($0.element)" }.joined(separator: "     ")

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = words.isEmpty ? .secondaryLabelColor : .labelColor
        label.sizeToFit()
        let padding = NSSize(width: 10, height: 5)
        let size = NSSize(width: label.frame.width + padding.width * 2, height: label.frame.height + padding.height * 2)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        label.frame.origin = NSPoint(x: padding.width, y: padding.height)
        background.addSubview(label)
        panel.contentView = background

        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caretRect.origin) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            if origin.y < visible.minY { origin.y = caretRect.maxY + 4 }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
        words = []
    }
}
