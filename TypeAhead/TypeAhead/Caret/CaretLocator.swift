import AppKit
import Vision

/// Locates the on-screen caret in apps whose AX caret rect is untrustworthy, by capturing the
/// focused window and finding the user's trailing typed text via on-device Vision OCR. Pure
/// math is delegated to `CaretGeometry`. Throttled/cached per window — Vision is an enhancement,
/// never blocking the keystroke path.
@MainActor
final class CaretLocator {

    /// Captures the focused-window image. Injected (not a direct `ScreenshotContextProvider`
    /// call) so this type depends only on AppKit+Vision and compiles in the SPM test target;
    /// the ScreenCaptureKit capture is wired from the app side. nil → Vision disabled, callers
    /// fall back to the pinned bar.
    var captureWindow: (() async -> NSImage?)?

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
            guard let image = await captureWindow(),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.cachedAnchor = nil
                self.cachedWindow = nil
                print("👁️ vision: capture FAILED (Screen Recording permission off?) — pinned/AX fallback")
                return
            }
            // OCR off the main thread; synchronous pattern (read request.results directly — no
            // continuation that could dangle if `perform` throws). Mirrors ScreenshotContextProvider.
            let observations = await Task.detached(priority: .userInitiated) {
                Self.recognizeText(in: cg)
            }.value
            let anchor = CaretGeometry.bestMatch(trailingText: trailing, observations: observations, in: windowFrame)
            self.cachedAnchor = anchor
            self.cachedWindow = windowFrame
            print("👁️ vision: \(observations.count) text lines, trailing='\(trailing.suffix(16))' → anchor=\(anchor.map { "(\(Int($0.origin.x)),\(Int($0.origin.y)))" } ?? "NO MATCH")")
        }
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
