import Testing
import Foundation
@testable import TypeAhead

/// Tests for the pure label/decision logic behind the status-bar menu — the per-app toggle
/// title, snooze state, effective-enabled gating, and the readiness header line.
@Suite struct StatusBarMenuLogicTests {

    // MARK: - perAppItemTitle

    @Test func perAppTitleSaysTurnOffWhenNotExcluded() {
        #expect(StatusBarMenuLogic.perAppItemTitle(appName: "Slack", isExcluded: false)
                == "Turn Off Suggestions in Slack")
    }

    @Test func perAppTitleSaysTurnOnWhenExcluded() {
        #expect(StatusBarMenuLogic.perAppItemTitle(appName: "Slack", isExcluded: true)
                == "Turn On Suggestions in Slack")
    }

    @Test func perAppTitleNilWhenNoAppName() {
        #expect(StatusBarMenuLogic.perAppItemTitle(appName: nil, isExcluded: false) == nil)
        #expect(StatusBarMenuLogic.perAppItemTitle(appName: "   ", isExcluded: false) == nil)
    }

    // MARK: - isPaused

    @Test func isPausedTrueWhenDeadlineInFuture() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(StatusBarMenuLogic.isPaused(pausedUntil: Date(timeIntervalSince1970: 5_000), now: now))
    }

    @Test func isPausedFalseWhenDeadlinePassed() {
        let now = Date(timeIntervalSince1970: 9_000)
        #expect(!StatusBarMenuLogic.isPaused(pausedUntil: Date(timeIntervalSince1970: 5_000), now: now))
    }

    @Test func isPausedFalseWhenNoDeadline() {
        #expect(!StatusBarMenuLogic.isPaused(pausedUntil: nil, now: Date()))
    }

    // MARK: - effectiveEnabled

    @Test func effectiveEnabledTrueWhenOnAndNotPaused() {
        #expect(StatusBarMenuLogic.effectiveEnabled(userEnabled: true, pausedUntil: nil, now: Date()))
    }

    @Test func effectiveEnabledFalseWhenPausedEvenIfOn() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(!StatusBarMenuLogic.effectiveEnabled(
            userEnabled: true, pausedUntil: Date(timeIntervalSince1970: 5_000), now: now))
    }

    @Test func effectiveEnabledFalseWhenUserDisabled() {
        #expect(!StatusBarMenuLogic.effectiveEnabled(userEnabled: false, pausedUntil: nil, now: Date()))
    }

    // MARK: - statusLine

    @Test func statusLineReady() {
        #expect(StatusBarMenuLogic.statusLine(modelName: "Gemma 4 E2B", isReady: true) == "Gemma 4 E2B · Ready")
    }

    @Test func statusLineLoading() {
        #expect(StatusBarMenuLogic.statusLine(modelName: "Qwen 3 1B", isReady: false) == "Qwen 3 1B · Loading…")
    }

    // MARK: - statusItemRecoveryDecision

    @Test func recoveryHealthyResetsStreakAndDoesNothing() {
        let decision = StatusBarMenuLogic.statusItemRecoveryDecision(
            isHealthy: true, previousConsecutiveUnhealthyChecks: 3, hasOpenedFallbackSettings: false)
        #expect(decision == .init(consecutiveUnhealthyChecks: 0, shouldRecreate: false, shouldOpenFallbackSettings: false))
    }

    @Test func recoveryFirstUnhealthyRecreatesWithoutFallback() {
        let decision = StatusBarMenuLogic.statusItemRecoveryDecision(
            isHealthy: false, previousConsecutiveUnhealthyChecks: 0, hasOpenedFallbackSettings: false)
        #expect(decision == .init(consecutiveUnhealthyChecks: 1, shouldRecreate: true, shouldOpenFallbackSettings: false))
    }

    @Test func recoverySecondConsecutiveUnhealthyOpensFallback() {
        let decision = StatusBarMenuLogic.statusItemRecoveryDecision(
            isHealthy: false, previousConsecutiveUnhealthyChecks: 1, hasOpenedFallbackSettings: false)
        #expect(decision == .init(consecutiveUnhealthyChecks: 2, shouldRecreate: true, shouldOpenFallbackSettings: true))
    }

    @Test func recoveryDoesNotReopenFallbackOnceAlreadyShown() {
        let decision = StatusBarMenuLogic.statusItemRecoveryDecision(
            isHealthy: false, previousConsecutiveUnhealthyChecks: 4, hasOpenedFallbackSettings: true)
        #expect(decision == .init(consecutiveUnhealthyChecks: 5, shouldRecreate: true, shouldOpenFallbackSettings: false))
    }
}
