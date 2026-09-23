import Foundation
import Testing
@testable import TypeAhead

/// `AppPolicyResolver` computes the effective per-app policy from three sources with a clear
/// precedence: an explicit per-app override wins over the legacy exclusion list, which together
/// with the global toggle forms the inherited default. Pure logic — no AppSettings/AX dependency.
@Suite struct AppPolicyResolverTests {

    @Test func defaultsToGlobalWhenNoOverrideAndNotExcluded() {
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: nil)
        #expect(p.completionsEnabled == true)
        #expect(p.tabKeyDisabled == false)
    }

    @Test func excludedListDisablesCompletionsWhenNoOverride() {
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: true, override: nil)
        #expect(p.completionsEnabled == false)
    }

    @Test func globalOffDisablesCompletions() {
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: false, excludedByList: false, override: nil)
        #expect(p.completionsEnabled == false)
    }

    @Test func explicitOverrideEnablesEvenWhenExcluded() {
        // A user who explicitly turns completions ON for an app overrides a legacy exclusion.
        let o = AppOverride(completionsEnabled: true, tabKeyDisabled: nil)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: true, override: o)
        #expect(p.completionsEnabled == true)
    }

    @Test func explicitOverrideDisablesEvenWhenGlobalOnAndNotExcluded() {
        let o = AppOverride(completionsEnabled: false, tabKeyDisabled: nil)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: o)
        #expect(p.completionsEnabled == false)
    }

    @Test func nilOverrideFieldsInheritDefaults() {
        // An override that exists only to record a Tab preference must not change completions.
        let o = AppOverride(completionsEnabled: nil, tabKeyDisabled: true)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: o)
        #expect(p.completionsEnabled == true)
        #expect(p.tabKeyDisabled == true)
    }

    @Test func tabDisabledDefaultsFalse() {
        let o = AppOverride(completionsEnabled: nil, tabKeyDisabled: nil)
        #expect(AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: o).tabKeyDisabled == false)
    }

    @Test func styleInstructionDefaultsToNil() {
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: nil)
        #expect(p.styleInstruction == nil)
    }

    @Test func styleInstructionPassesThroughFromOverride() {
        let o = AppOverride(completionsEnabled: nil, tabKeyDisabled: nil, styleInstruction: "Keep it terse and casual.")
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: o)
        #expect(p.styleInstruction == "Keep it terse and casual.")
    }

    // MARK: - A3: the global toggle is a master switch

    @Test func globalOffBeatsExplicitPerAppOn() {
        // Turning TypeAhead off in Settings must stop completions everywhere — an app the user
        // once set to "On" must not keep suggesting while the global switch is off.
        let o = AppOverride(completionsEnabled: true)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: false, excludedByList: false, override: o)
        #expect(p.completionsEnabled == false)
    }

    @Test func globalOffBeatsExplicitPerAppOnEvenWhenExcluded() {
        let o = AppOverride(completionsEnabled: true)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: false, excludedByList: true, override: o)
        #expect(p.completionsEnabled == false)
    }

    // MARK: - B5: per-app typing-history recording

    @Test func recordHistoryFollowsGlobalByDefault() {
        #expect(AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: nil,
                                          globalRecordHistory: true).recordHistory == true)
        #expect(AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: nil,
                                          globalRecordHistory: false).recordHistory == false)
    }

    @Test func perAppRecordHistoryOffBeatsGlobalOn() {
        let o = AppOverride(recordHistory: false)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: o,
                                          globalRecordHistory: true)
        #expect(p.recordHistory == false)
    }

    @Test func perAppRecordHistoryOnCannotBeatGlobalOff() {
        // The global "Collect inputs" toggle is the privacy master switch: when it's off,
        // nothing is recorded anywhere, whatever an app override says.
        let o = AppOverride(recordHistory: true)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: o,
                                          globalRecordHistory: false)
        #expect(p.recordHistory == false)
    }

    // MARK: - B9: per-app compatibility mode

    @Test func compatibilityModeDefaultsOff() {
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: nil)
        #expect(p.compatibilityMode == false)
    }

    @Test func compatibilityModePassesThroughFromOverride() {
        let o = AppOverride(compatibilityMode: true)
        let p = AppPolicyResolver.resolve(globalCompletionsEnabled: true, excludedByList: false, override: o)
        #expect(p.compatibilityMode == true)
    }

    // MARK: - Persistence compatibility

    @Test func overrideSavedBeforeNewFieldsStillDecodes() throws {
        // Overrides persisted by earlier builds have no recordHistory/compatibilityMode keys.
        let json = #"{"completionsEnabled":false,"tabKeyDisabled":true}"#.data(using: .utf8)!
        let o = try JSONDecoder().decode(AppOverride.self, from: json)
        #expect(o.completionsEnabled == false)
        #expect(o.tabKeyDisabled == true)
        #expect(o.recordHistory == nil)
        #expect(o.compatibilityMode == nil)
    }

    // MARK: - A9 / B3: per-app on/off, independent of the global switch

    @Test func perAppEnabledFollowsExclusionListWithoutOverride() {
        #expect(AppPolicyResolver.perAppCompletionsEnabled(excludedByList: false, override: nil))
        #expect(!AppPolicyResolver.perAppCompletionsEnabled(excludedByList: true, override: nil))
    }

    @Test func perAppEnabledPrefersExplicitOverride() {
        #expect(AppPolicyResolver.perAppCompletionsEnabled(excludedByList: true, override: AppOverride(completionsEnabled: true)))
        #expect(!AppPolicyResolver.perAppCompletionsEnabled(excludedByList: false, override: AppOverride(completionsEnabled: false)))
    }
}
