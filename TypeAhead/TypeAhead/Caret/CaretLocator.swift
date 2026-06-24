import AppKit
import Vision

/// Locates the on-screen caret in apps whose AX caret rect is untrustworthy, by capturing the
/// focused window and finding the user's trailing typed text via on-device Vision OCR. Pure
/// math is delegated to `CaretGeometry`. Throttled/cached per window — Vision is an enhancement,
/// never blocking the keystroke path.
@MainActor
final class CaretLocator {

    /// Captures the focused-window image plus the window's frame (Quartz/SCKit global, TOP-left
    /// origin). Injected (not a direct `ScreenshotContextProvider` call) so this type depends only
    /// on AppKit+Vision and compiles in the SPM test target; the ScreenCaptureKit capture is wired
    /// from the app side. nil → Vision disabled, callers fall back to the pinned bar. The returned
    /// frame is the region actually captured, so OCR boxes map against it directly.
    var captureWindow: (() async -> (image: NSImage, topLeftFrame: CGRect)?)?

    /// Cached caret anchor + the window frame and time it was computed for.
    private(set) var cachedAnchor: NSRect?
    private var cachedWindow: NSRect?
    private var lastComputed: Date = .distantPast
    private var inFlight = false
    private let ttl: TimeInterval = 1.0

    /// Pure freshness rule: the cached anchor is usable only for the SAME window and within the
    /// TTL. Extracted for unit testing. A window-identity check prevents a stale anchor from the
    /// previous window showing after an Alt-Tab inside the TTL.
    nonisolated static func isAnchorFresh(cachedAt: Date, cachedWindow: NSRect, requestWindow: NSRect,
                                          now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(cachedAt) < ttl && cachedWindow == requestWindow
    }

    /// A fresh cached anchor for `windowFrame` (same window, within TTL), else nil.
    func freshAnchor(forWindow windowFrame: NSRect, now: Date = Date()) -> NSRect? {
        guard let anchor = cachedAnchor, let cachedWindow,
              Self.isAnchorFresh(cachedAt: lastComputed, cachedWindow: cachedWindow,
                                 requestWindow: windowFrame, now: now, ttl: ttl) else { return nil }
        return anchor
    }

    /// The cached anchor for `windowFrame` regardless of TTL — stale but pixel-accurate.
    /// Use as a fallback rung between fresh Vision and AX: a 2-second-old OCR anchor beats
    /// the hardcoded window-corner PINNED bar.
    func staleAnchor(forWindow windowFrame: NSRect) -> NSRect? {
        guard let anchor = cachedAnchor, cachedWindow == windowFrame else { return nil }
        return anchor
    }

    /// Test-only: populate the anchor cache without going through the async capture path.
    func testInjectAnchor(_ anchor: NSRect, window: NSRect) {
        cachedAnchor = anchor
        cachedWindow = window
        lastComputed = .distantPast   // treat as expired so freshAnchor returns nil
    }

    /// Kicks off a throttled background capture+OCR that updates `cachedAnchor`. Safe to call on
    /// every keystroke — it no-ops while one is in flight, within the TTL, or with no capture.
    func refresh(trailingText: String, windowFrame: NSRect, now: Date = Date()) {
        guard let captureWindow else { return }
        guard !inFlight, now.timeIntervalSince(lastComputed) >= ttl else { return }
        guard trailingText.count >= 3 else { return }
        inFlight = true
        let trailing = trailingText
        Task { @MainActor in
            defer { self.inFlight = false; self.lastComputed = Date() }
            guard let captured = await captureWindow(),
                  let cg = captured.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.cachedAnchor = nil
                self.cachedWindow = nil
                print("👁️ vision: capture FAILED (Screen Recording permission off?) — pinned/AX fallback")
                return
            }
            // Map OCR boxes against the region that was ACTUALLY captured, not the AX window
            // frame — any drift between the two coordinate sources would otherwise shift every
            // anchor. Flip the SCKit top-left frame into Cocoa screen coords.
            let menuBarHeight = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
            let captureFrame = CaretGeometry.flipToCocoa(topLeftFrame: captured.topLeftFrame, menuBarHeight: menuBarHeight)
            if abs(captureFrame.minX - windowFrame.minX) > 2 || abs(captureFrame.minY - windowFrame.minY) > 2 {
                print("👁️ vision: capture frame \(rectStr(captureFrame)) ≠ AX frame \(rectStr(windowFrame)) — using capture frame")
            }
            // OCR off the main thread; synchronous pattern (read request.results directly — no
            // continuation that could dangle if `perform` throws). Mirrors ScreenshotContextProvider.
            let observations = await Task.detached(priority: .userInitiated) {
                Self.recognizeText(in: cg)
            }.value
            let anchor = CaretGeometry.bestMatch(trailingText: trailing, observations: observations, in: captureFrame)
            if let anchor {
                self.cachedAnchor = anchor
                self.cachedWindow = windowFrame
            }
            // On NO MATCH leave cachedAnchor/cachedWindow intact — a stale-but-real anchor is
            // better than snapping to the pinned bar. It expires naturally via lastComputed+TTL.
            let anchorDesc = anchor.map { "(\(Int($0.origin.x)),\(Int($0.origin.y)))" }
                ?? (cachedAnchor != nil ? "NO MATCH (kept prev \(Int(cachedAnchor!.origin.x)),\(Int(cachedAnchor!.origin.y)))" : "NO MATCH")
            print("👁️ vision: \(observations.count) text lines, trailing='\(trailing.suffix(16))' → anchor=\(anchorDesc)")
        }
    }

    private func rectStr(_ r: NSRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))×\(Int(r.height)))"
    }

    /// Runs Vision text recognition and adapts results into `CaretGeometry.Observation`s.
    nonisolated private static func recognizeText(in image: CGImage) -> [CaretGeometry.Observation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return CaretGeometry.Observation(text: top.string, box: obs.boundingBox)
        }
    }
}
