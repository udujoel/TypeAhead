import AppKit
import Carbon

@MainActor
final class KeyEventMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onKeystroke: ((NSEvent) -> Void)?
    var onTabPressed: (() -> Void)?
    var onShiftTabPressed: (() -> Void)?
    var onDismiss: (() -> Void)?

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleLocal(event: event) ?? event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor  { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor  = nil
    }

    private func handle(event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Tab) else { return }
        onKeystroke?(event)
    }

    private func handleLocal(event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case UInt16(kVK_Tab):
            if event.modifierFlags.contains(.shift) {
                onShiftTabPressed?()
            } else {
                onTabPressed?()
            }
            return nil
        case UInt16(kVK_Escape):
            onDismiss?()
            return event
        default:
            onKeystroke?(event)
            return event
        }
    }
}
