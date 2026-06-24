import Foundation

/// Pure, AppKit-free label/decision logic for the status-bar menu. Extracted from
/// `StatusBarMenu` (which is excluded from the SPM test target) so the user-facing
/// strings and state decisions can be unit-tested without the full app bundle.
enum StatusBarMenuLogic {

    /// Title for the per-app "exclude this app" toggle, given the frontmost app's name and
    /// whether it's already excluded. Returns nil when there's no eligible app to target
    /// (no name, or TypeAhead itself is frontmost) — callers omit the item entirely.
    static func perAppItemTitle(appName: String?, isExcluded: Bool) -> String? {
        guard let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return isExcluded ? "Turn On Suggestions in \(name)" : "Turn Off Suggestions in \(name)"
    }

    /// Whether suggestions are currently snoozed (a pause deadline exists and is still in the future).
    static func isPaused(pausedUntil: Date?, now: Date) -> Bool {
        guard let until = pausedUntil else { return false }
        return until > now
    }

    /// The completion engine is "live" only when the user has suggestions on AND isn't snoozed.
    /// Drives the pipeline's enabled flag so a pause auto-restores without touching the saved
    /// preference.
    static func effectiveEnabled(userEnabled: Bool, pausedUntil: Date?, now: Date) -> Bool {
        userEnabled && !isPaused(pausedUntil: pausedUntil, now: now)
    }

    /// One-line header describing engine readiness, e.g. "Gemma 4 E2B · Ready" / "… · Loading…".
    static func statusLine(modelName: String, isReady: Bool) -> String {
        "\(modelName) · \(isReady ? "Ready" : "Loading…")"
    }
}
