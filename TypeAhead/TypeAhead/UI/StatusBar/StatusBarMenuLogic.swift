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

    /// B4: how long a snooze lasts.
    enum SnoozeOption: CaseIterable, Sendable {
        case fifteenMinutes, oneHour, untilTomorrowMorning

        var title: String {
            switch self {
            case .fifteenMinutes: "Pause for 15 Minutes"
            case .oneHour: "Pause for 1 Hour"
            case .untilTomorrowMorning: "Pause Until Tomorrow Morning"
            }
        }

        /// When suggestions resume. "Tomorrow morning" is 8:00 on the next calendar day.
        func deadline(from now: Date, calendar: Calendar) -> Date {
            switch self {
            case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
            case .oneHour: return now.addingTimeInterval(3600)
            case .untilTomorrowMorning:
                let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                    ?? now.addingTimeInterval(24 * 3600)
                return calendar.date(byAdding: .hour, value: 8, to: startOfTomorrow)
                    ?? startOfTomorrow
            }
        }
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

    // MARK: - Status-item health recovery

    /// Outcome of a single status-item health check: whether to tear down and recreate the
    /// item, the updated consecutive-unhealthy streak, and whether this is the moment to fall
    /// back to opening Settings (recreation didn't stick — twice unhealthy in a row).
    struct StatusItemRecoveryDecision: Equatable {
        let consecutiveUnhealthyChecks: Int
        let shouldRecreate: Bool
        let shouldOpenFallbackSettings: Bool
    }

    /// Decides what a health check should do given the current health signal and prior state.
    /// A healthy item resets the streak and does nothing. An unhealthy item always triggers a
    /// recreate attempt; the fallback (opening Settings so the user always has a reachable
    /// surface) fires only when this is the second consecutive unhealthy check — i.e. the
    /// previous recreate didn't stick — and only once per app run.
    static func statusItemRecoveryDecision(
        isHealthy: Bool,
        previousConsecutiveUnhealthyChecks: Int,
        hasOpenedFallbackSettings: Bool
    ) -> StatusItemRecoveryDecision {
        guard !isHealthy else {
            return StatusItemRecoveryDecision(
                consecutiveUnhealthyChecks: 0, shouldRecreate: false, shouldOpenFallbackSettings: false)
        }
        let count = previousConsecutiveUnhealthyChecks + 1
        let openFallback = count >= 2 && !hasOpenedFallbackSettings
        return StatusItemRecoveryDecision(
            consecutiveUnhealthyChecks: count, shouldRecreate: true, shouldOpenFallbackSettings: openFallback)
    }
}
