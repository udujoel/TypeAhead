import Foundation
import CoreGraphics

/// Pure geometry + text-matching for Vision-based caret location. No Vision/AppKit I/O here so
/// it runs under `swift test`. `CaretLocator` feeds it recognized text + normalized boxes.
enum CaretGeometry {

    /// A recognized line of on-screen text and its bounding box in Vision's normalized
    /// coordinate space (origin bottom-left, axes in [0, 1] relative to the captured image).
    struct Observation: Sendable, Equatable {
        let text: String
        let box: CGRect
    }

    /// Maps a Vision normalized rect (bottom-left origin) to screen coordinates within
    /// `windowFrame` (Cocoa, bottom-left origin). The captured image fills the window frame.
    static func screenRect(fromNormalized norm: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + norm.minX * windowFrame.width,
            y: windowFrame.minY + norm.minY * windowFrame.height,
            width: norm.width * windowFrame.width,
            height: norm.height * windowFrame.height
        )
    }

    /// Finds the observation whose text best contains the user's `trailingText` (the last few
    /// typed characters) and returns a zero-width caret anchor at the RIGHT edge of its box,
    /// in screen coordinates. Returns nil when no observation matches confidently.
    static func bestMatch(trailingText: String, observations: [Observation], in windowFrame: CGRect) -> CGRect? {
        let needle = normalize(trailingText)
        guard needle.count >= 3 else { return nil }

        var best: Observation?
        var bestScore = 0
        for obs in observations {
            let hay = normalize(obs.text)
            let score = matchScore(needle: needle, haystack: hay)
            if score > bestScore {
                bestScore = score
                best = obs
            }
        }
        // Require a strong match: at least ~70% of the needle length found.
        guard let match = best, bestScore >= max(3, (needle.count * 7) / 10) else { return nil }
        let boxScreen = screenRect(fromNormalized: match.box, in: windowFrame)
        return CGRect(x: boxScreen.maxX, y: boxScreen.minY, width: 0, height: boxScreen.height)
    }

    /// Longest suffix of `needle` that appears in `haystack` (case/space-normalized), as a
    /// crude confidence score. Cheap and good enough to pick the caret line.
    static func matchScore(needle: String, haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var k = needle.count
        while k >= 3 {
            let suffix = String(needle.suffix(k))
            if haystack.contains(suffix) { return k }
            k -= 1
        }
        return 0
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }
}
