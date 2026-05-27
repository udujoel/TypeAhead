import Testing
@testable import TypeAhead

@Suite struct AppSettingsTests {
    @Test func defaultsAreCorrect() {
        let settings = AppSettings()
        #expect(settings.completionsEnabled == true)
        #expect(settings.completionDelay == 0.12)
        #expect(settings.completionLength == .medium)
        #expect(settings.activeModelID == ModelConfig.defaultModel.id)
        #expect(settings.showInAllApps == true)
    }

    @Test func completionLengthTokenBudget() {
        #expect(CompletionLength.short.maxTokens == 20)
        #expect(CompletionLength.medium.maxTokens == 40)
        #expect(CompletionLength.long.maxTokens == 80)
    }

    @Test func exceptionListRoundTrips() {
        var list = AppExceptionList()
        list.add(bundleID: "com.example.app")
        #expect(list.isExcluded(bundleID: "com.example.app"))
        list.remove(bundleID: "com.example.app")
        #expect(!list.isExcluded(bundleID: "com.example.app"))
    }

    @Test func defaultExclusionListContainsPasswordManagers() {
        let list = AppExceptionList.defaults
        #expect(list.isExcluded(bundleID: "com.agilebits.onepassword7"))
        #expect(list.isExcluded(bundleID: "desktop.Bitwarden"))
    }
}
