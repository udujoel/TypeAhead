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

    /// Flips a frame from the Quartz/ScreenCaptureKit global space (TOP-left origin, Y down) to
    /// Cocoa screen coordinates (BOTTOM-left origin, Y up). `menuBarHeight` is the primary screen's
    /// Cocoa `frame.maxY` (its full height), the axis both spaces share. Used to convert an
    /// `SCWindow.frame` into the same coordinate space the overlay positions in — so the Vision
    /// mapping uses the region that was actually captured, not a separately-measured AX frame.
    static func flipToCocoa(topLeftFrame f: CGRect, menuBarHeight: CGFloat) -> CGRect {
        CGRect(x: f.minX, y: menuBarHeight - f.maxY, width: f.width, height: f.height)
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
    ///
    /// Two match directions are tried and the higher score wins:
    /// - `matchScore`: needle suffix appears in haystack (classic case).
    /// - `leadingPrefixScore`: needle starts with haystack (OCR captured earlier partial text).
    /// Threshold is capped at 8 chars so a long needle doesn't demand an impossibly long match.
    ///
    /// Ties break toward the **bottom-most** observation: the text the user is actively typing
    /// lives in the compose box, which sits at the bottom of virtually every chat app, so on an
    /// equal score the lower box (smaller normalized minY, bottom-left origin) is the live caret
    /// — not an identical phrase echoed in the scrollback above.
    static func bestMatch(trailingText: String, observations: [Observation], in windowFrame: CGRect) -> CGRect? {
        let needle = normalize(trailingText)
        guard needle.count >= 3 else { return nil }
        let threshold = max(3, (min(needle.count, 8) * 7) / 10)

        var best: Observation?
        var bestScore = 0
        for obs in observations {
            let hay = normalize(obs.text)
            let score = max(matchScore(needle: needle, haystack: hay),
                            leadingPrefixScore(needle: needle, haystack: hay))
            guard score > 0 else { continue }
            let beatsOnScore = score > bestScore
            let tiesButLower = score == bestScore && (best.map { obs.box.minY < $0.box.minY } ?? false)
            if beatsOnScore || tiesButLower {
                bestScore = score
                best = obs
            }
        }
        guard let match = best, bestScore >= threshold else { return nil }
        let boxScreen = screenRect(fromNormalized: match.box, in: windowFrame)
        return CGRect(x: boxScreen.maxX, y: boxScreen.minY, width: 0, height: boxScreen.height)
    }

    /// How many leading chars of `haystack` match the start of `needle`. Handles the case where
    /// Vision captured a slightly stale snapshot — the OCR text is a prefix of the current typed
    /// text (e.g. haystack="check re", needle="check review from the PR").
    static func leadingPrefixScore(needle: String, haystack: String) -> Int {
        guard !haystack.isEmpty, !needle.isEmpty else { return 0 }
        var k = min(haystack.count, needle.count)
        while k >= 3 {
            if needle.hasPrefix(String(haystack.prefix(k))) { return k }
            k -= 1
        }
        return 0
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
