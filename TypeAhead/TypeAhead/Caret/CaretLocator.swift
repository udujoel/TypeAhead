import AppKit
import Vision

/// Locates the on-screen caret in apps whose AX caret rect is untrustworthy, by capturing the
/// focused window and finding the user's trailing typed text via on-device Vision OCR. Pure
/// math is delegated to `CaretGeometry`. Throttled/cached per window — Vision is an enhancement,
/// never blocking the keystroke path.
@MainActor
final class CaretLocator {

    /// Cached caret anchor for the current focused window + the time it was computed.
    private(set) var cachedAnchor: NSRect?
    private var lastComputed: Date = .distantPast
    private var inFlight = false
    private let ttl: TimeInterval = 1.0

    /// A fresh cached anchor if one was computed within the TTL, else nil.
    func freshAnchor(now: Date = Date()) -> NSRect? {
        guard let anchor = cachedAnchor, now.timeIntervalSince(lastComputed) < ttl else { return nil }
        return anchor
    }

    /// Kicks off a throttled background capture+OCR that updates `cachedAnchor`. Safe to call on
    /// every keystroke — it no-ops while one is in flight or within the TTL.
    func refresh(trailingText: String, windowFrame: NSRect, now: Date = Date()) {
        guard !inFlight, now.timeIntervalSince(lastComputed) >= ttl else { return }
        guard trailingText.count >= 3 else { return }
        inFlight = true
        let trailing = trailingText
        Task { @MainActor in
            defer { self.inFlight = false; self.lastComputed = Date() }
            guard let image = await ScreenshotContextProvider.captureActiveWindow(),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.cachedAnchor = nil
                return
            }
            let observations = await Self.recognizeText(in: cg)
            self.cachedAnchor = CaretGeometry.bestMatch(
                trailingText: trailing, observations: observations, in: windowFrame)
        }
    }

    /// Runs Vision text recognition and adapts results into `CaretGeometry.Observation`s.
    private static func recognizeText(in image: CGImage) async -> [CaretGeometry.Observation] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let results = (request.results as? [VNRecognizedTextObservation]) ?? []
                let observations: [CaretGeometry.Observation] = results.compactMap { obs in
                    guard let top = obs.topCandidates(1).first else { return nil }
                    return CaretGeometry.Observation(text: top.string, box: obs.boundingBox)
                }
                continuation.resume(returning: observations)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }
}
