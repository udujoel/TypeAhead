import AppKit
import ScreenCaptureKit
import Vision

enum ScreenshotContextProvider {
    static func captureActiveWindow() async -> NSImage? {
        // Make sure the user has granted screen capture permission
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        // Ask ScreenCaptureKit for the list of windows currently on screen
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }

        let pid = app.processIdentifier
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid
        }) else { return nil }

        // Scope the capture to just this one window
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = false

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Captures the frontmost window and runs fast OCR via Vision.
    /// Returns up to `maxChars` of extracted text — enough for the LLM to understand
    /// the user's current topic without inflating the prompt with off-task content.
    /// The OCR runs on a background thread so the main actor is not blocked.
    static func captureAndExtractText(maxChars: Int = 200) async -> String? {
        guard let image = await captureActiveWindow() else { return nil }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage)
            try? handler.perform([request])

            // Filter out low-confidence observations and symbol-heavy lines (OCR artifacts
            // from app UI controls, icons, or decorative glyphs that produce junk like "•••"
            // or "Ll8?.G•..." — those garble LLM completions when injected as screen context).
            let lines = (request.results ?? []).compactMap { obs -> String? in
                guard let top = obs.topCandidates(1).first,
                      top.confidence >= 0.4 else { return nil }
                let s = top.string
                guard s.count >= 3 else { return nil }
                let alphaCount = s.filter { $0.isLetter || $0.isNumber || $0 == " " }.count
                guard Double(alphaCount) / Double(s.count) >= 0.6 else { return nil }
                return s
            }
            let joined = lines.joined(separator: " ")
            let trimmed = String(joined.prefix(maxChars))
            return trimmed.isEmpty ? nil : trimmed
        }.value
    }
}
