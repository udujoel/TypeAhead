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
}
