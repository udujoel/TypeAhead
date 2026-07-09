import AppKit
import Carbon
import os
@preconcurrency import CoreGraphics

// MARK: - Keystroke Buffer

/// Tracks characters the user has recently typed so completions can fire
/// even when the Accessibility API can't read the focused text field.
@MainActor
final class KeystrokeBuffer {
    private(set) var text: String = ""
    private let capacity = 400

    /// Feed every keyDown event through here to maintain the buffer.
    func process(_ event: NSEvent) {
        // Ignore key combos (Cmd-C, Ctrl-A, etc.) — those aren't text input
        let used = event.modifierFlags.intersection([.command, .control, .option])
        guard used.isEmpty else { return }

        switch Int(event.keyCode) {
        case kVK_Delete:                                // backspace
            if !text.isEmpty { text.removeLast() }
        case kVK_ForwardDelete:
            break                                       // can't track without cursor pos
        case kVK_LeftArrow, kVK_RightArrow,
             kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            text = ""                                   // navigation = lost cursor context
        case kVK_Return, kVK_ANSI_KeypadEnter:
            text += "\n"
        case kVK_Escape, kVK_Tab:
            break                                       // handled elsewhere
        default:
            guard let chars = event.characters else { return }
            // Keep printable Unicode characters (exclude C0/C1 control chars)
            let printable = String(chars.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
            guard !printable.isEmpty else { return }
            text += printable
            if text.count > capacity { text = String(text.suffix(capacity)) }
        }
    }

    /// Call this after a completion is accepted so the buffer stays accurate.
    func appendAccepted(_ completion: String) {
        text += completion
        if text.count > capacity { text = String(text.suffix(capacity)) }
    }

    /// Replace the last `count` characters with `replacement` (e.g. after emoji or spell-correction acceptance).
    func replaceTrailing(count: Int, with replacement: String) {
        if count > 0 && text.count >= count {
            text = String(text.dropLast(count)) + replacement
        } else {
            text = replacement
        }
        if text.count > capacity { text = String(text.suffix(capacity)) }
    }

    func clear() { text = "" }
}

// MARK: - Key Event Monitor

@MainActor
final class KeyEventMonitor {
    private let logger = Logger(subsystem: "app.typeahead", category: "KeyEventMonitor")

    // MARK: Public state

    let keystrokeBuffer = KeystrokeBuffer()

    /// Set to true while the completion overlay is visible.
    /// Tab is swallowed (not forwarded to the target app) only when this is true.
    var isOverlayVisible = false

    // MARK: Callbacks wired up by AppDelegate

    var onKeystroke: ((NSEvent) -> Void)?
    var onTabPressed: (() -> Void)?
    var onShiftTabPressed: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Fired on the global ⌃⌥⌘T shortcut — opens the status menu even when its menu-bar icon
    /// is hidden (notch overflow), so the app is always reachable.
    var onShowMenu: (() -> Void)?

    // MARK: Private

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var fallbackGlobalMonitor: Any?

    // C-convention CGEventTap callbacks can't capture `self` directly.
    // We use a module-level weak reference instead.
    nonisolated(unsafe) static weak var instance: KeyEventMonitor?

    // MARK: - Lifecycle

    func start() {
        KeyEventMonitor.instance = self
        startEventTap()
        // Local monitor handles events in TypeAhead's own windows (Settings).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keystrokeBuffer.process(event)
            return self?.handleLocal(event: event) ?? event
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        if let g = fallbackGlobalMonitor { NSEvent.removeMonitor(g) }
        localMonitor = nil
        fallbackGlobalMonitor = nil
        KeyEventMonitor.instance = nil
    }

    // MARK: - CGEventTap setup

    private func startEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                // can swallow events by returning nil
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                MainActor.assumeIsolated {
                    // Only fall back to passthrough when there's no monitor. handleGlobal
                    // returns nil to *swallow* (e.g. Tab) — that nil must be returned as-is,
                    // not coalesced to passthrough, or the swallowed key still reaches the app.
                    guard let monitor = KeyEventMonitor.instance else {
                        return Unmanaged.passRetained(event)
                    }
                    return monitor.handleGlobal(type: type, event: event)
                }
            },
            userInfo: nil
        )

        guard let tap else {
            logger.error("CGEventTap creation failed (Accessibility not trusted?) — using NSEvent fallback (Tab cannot be swallowed)")
            startFallbackMonitor()
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
        logger.info("CGEventTap started — Tab will be intercepted when overlay is visible")
    }

    /// Fallback when CGEventTap can't be created (permission not yet granted).
    private func startFallbackMonitor() {
        fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.keystrokeBuffer.process(event)
                // Note: in fallback mode, Tab cannot be swallowed.
                guard event.keyCode != UInt16(kVK_Tab) else { return }
                self.onKeystroke?(event)
            }
        }
    }

    // MARK: - Event handling

    /// Fires for every keyDown in any app (via CGEventTap).
    /// Returns `nil` to swallow the event, or the original event to pass it through.
    private func handleGlobal(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables the tap if a callback runs too long (or on certain user input).
        // Re-enable it immediately, otherwise Tab interception silently dies and Tab
        // starts changing focus again.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            logger.error("event tap disabled (\(type.rawValue, privacy: .public)) — re-enabled")
            return nil
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // Ignore events that we ourselves injected
        if event.getIntegerValueField(.eventSourceUserData) == AccessibilityManager.injectedEventMarker {
            return Unmanaged.passRetained(event)
        }

        // Ignore events in TypeAhead's own windows (handled by localMonitor)
        if NSApp.keyWindow != nil {
            return Unmanaged.passRetained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Global ⌃⌥⌘T — open the status menu regardless of icon visibility. Matches only when
        // Control+Option+Command are the exact modifiers (no Shift), so it can't be hit by accident.
        let menuMods = event.flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate])
        if keyCode == CGKeyCode(kVK_ANSI_T), menuMods == [.maskControl, .maskAlternate, .maskCommand] {
            Task { @MainActor [weak self] in self?.onShowMenu?() }
            return nil  // swallowed — the target app never sees this combo
        }

        // Tab — swallow and accept completion when overlay is up.
        if keyCode == CGKeyCode(kVK_Tab) {
            if isOverlayVisible {
                let shifted = event.flags.contains(.maskShift)
                // Defer the accept: inserting text does AX / CGEvent work that's too slow to
                // run inside this callback. A slow callback makes the OS disable the tap and
                // lets the Tab through (the "Tab also changes focus" bug). Returning nil now
                // guarantees the Tab is swallowed; the word is inserted a beat later.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if shifted { self.onShiftTabPressed?() } else { self.onTabPressed?() }
                }
                return nil  // ← swallowed immediately: the app never sees this Tab
            }
            return Unmanaged.passRetained(event)
        }

        // Escape — notify but don't swallow
        if keyCode == CGKeyCode(kVK_Escape) {
            onDismiss?()
            return Unmanaged.passRetained(event)
        }

        // Option+Right Arrow — alternate accept key for apps where Tab is consumed (browsers, terminals).
        // Only fires when Option is the *sole* modifier: ⇧⌥→ (select word forward) passes through.
        // Task spawn frequency is not a concern: onTabPressed hides the overlay, so isOverlayVisible
        // becomes false before any repeat event arrives and subsequent events fall through below.
        let optionOnly = event.flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate]) == .maskAlternate
        if keyCode == CGKeyCode(kVK_RightArrow) && optionOnly {
            if isOverlayVisible {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.onTabPressed?()
                }
                return nil  // swallowed — app never sees this ⌥→
            }
            // Overlay not visible — pass through, but fall into the block below so
            // onKeystroke? fires and cancels any in-flight inference (CLAUDE.md rule).
        }

        // All other keys — update buffer and trigger completion pipeline
        if let nsEvent = NSEvent(cgEvent: event) {
            keystrokeBuffer.process(nsEvent)
            onKeystroke?(nsEvent)
        }
        return Unmanaged.passRetained(event)
    }

    /// Fires for keyDown events in TypeAhead's own windows (Settings, etc.).
    private func handleLocal(event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case UInt16(kVK_Tab):
            if event.modifierFlags.contains(.shift) { onShiftTabPressed?() }
            else { onTabPressed?() }
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
