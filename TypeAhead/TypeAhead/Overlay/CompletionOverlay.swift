import AppKit

@MainActor
final class CompletionOverlay {
    private let panel: NSPanel
    private let label: NSTextField
    /// Rounded, semi-opaque backdrop shown only behind the mirror presentation — inline mode
    /// stays fully transparent/backgroundless as before. Sits behind `label` in z-order; hidden
    /// whenever the panel isn't in mirror mode (including every `hide()`, so a stale background
    /// never lingers behind the next inline show).
    private let mirrorBackground: NSView

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

        mirrorBackground = NSView(frame: .zero)
        mirrorBackground.wantsLayer = true
        mirrorBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        mirrorBackground.layer?.cornerRadius = 6
        mirrorBackground.layer?.borderWidth = 1
        mirrorBackground.layer?.borderColor = NSColor.separatorColor.cgColor
        mirrorBackground.isHidden = true

        label = NSTextField(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.textColor = NSColor.tertiaryLabelColor
        panel.contentView?.addSubview(mirrorBackground)
        panel.contentView?.addSubview(label)
    }

    // MARK: - Show / Update / Hide (inline — caret-anchored, backgroundless)

    /// The ghost's on-screen frame while it's showing (inline or mirror) — where the word
    /// alternatives list anchors.
    var visibleFrame: NSRect? {
        panel.isVisible && panel.alphaValue > 0 ? panel.frame : nil
    }

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

    // MARK: - Show / Update (mirror — two-tone typed-tail + ghost, own backdrop)

    /// Cotypist-style mirror: `typed` renders in the normal text color immediately followed by
    /// `ghost` in the ghost (tertiary) color, reading as one continuous line. `rect` is the
    /// placement's rect for this cycle — for the `.elementFrame` tier that's the RAW focused
    /// element frame (positioning computed here via `OverlayPositioner.mirrorOrigin`); for every
    /// other tier (`.approximate`) it's already a computed origin point, positioned the same way
    /// `show(text:near:fontSize:)` positions inline ghosts.
    func showMirror(typed: String, ghost: String, near rect: NSRect, fontSize: CGFloat, tier: PlacementTier) {
        label.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        renderMirrorText(typed: typed, ghost: ghost)
        repositionMirrorPanel(rect: rect, tier: tier)
        panel.alphaValue = 1
        panel.orderFront(nil)
    }

    func updateMirror(typed: String, ghost: String, near rect: NSRect, tier: PlacementTier) {
        renderMirrorText(typed: typed, ghost: ghost)
        repositionMirrorPanel(rect: rect, tier: tier)
    }

    /// - Parameter animated: Pass `false` on keystroke for an instant hide (no flicker).
    ///   Pass `true` for a gentle fade on explicit dismiss (Escape, timeout).
    func hide(animated: Bool = true) {
        mirrorBackground.isHidden = true
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

    /// Small inset so the two-tone text doesn't touch the rounded backdrop's edges.
    private static let mirrorInset: CGFloat = 8

    private func renderMirrorText(typed: String, ghost: String) {
        mirrorBackground.isHidden = false
        let font = label.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
        let attributed = NSMutableAttributedString(
            string: typed, attributes: [.foregroundColor: NSColor.labelColor, .font: font])
        attributed.append(NSAttributedString(
            string: ghost, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: font]))
        label.attributedStringValue = attributed
        label.sizeToFit()
    }

    private func repositionMirrorPanel(rect: NSRect, tier: PlacementTier) {
        let inset = Self.mirrorInset
        let panelWidth = min(label.frame.width + inset * 2, 600)
        let panelHeight = label.frame.height + inset
        let panelSize = NSSize(width: panelWidth, height: panelHeight)
        // `.elementFrame` carries the RAW element frame — mirror-specific below/above-flip
        // positioning applies. Every other mirror-eligible tier (`.approximate`) already carries
        // a pre-computed origin point (0-width rect), positioned the same way inline ghosts are.
        let origin: NSPoint
        switch tier {
        case .elementFrame:
            origin = OverlayPositioner.mirrorOrigin(elementFrame: rect, panelSize: panelSize)
        default:
            origin = OverlayPositioner.inlineOrigin(cursorRect: rect, panelSize: panelSize)
        }
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        mirrorBackground.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        label.frame = NSRect(x: inset, y: inset / 2, width: panelWidth - inset * 2, height: label.frame.height)
    }
}
