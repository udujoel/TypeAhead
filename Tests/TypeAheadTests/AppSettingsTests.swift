import Testing
@testable import TypeAhead

@Suite struct AppSettingsTests {
    @Test func defaultsAreCorrect() {
        let settings = AppSettings()
        #expect(settings.completionsEnabled == true)
        #expect(settings.completionDelay == 0.35)
        #expect(settings.completionLength == .medium)
        #expect(settings.activeModelID == ModelConfig.defaultModel.id)
        #expect(settings.showInAllApps == true)
    }

    @Test func completionLengthTokenBudget() {
        #expect(CompletionLength.short.maxTokens == 16)
        #expect(CompletionLength.medium.maxTokens == 32)
        #expect(CompletionLength.long.maxTokens == 64)
    }

    @Test func completionLengthWordCap() {
        #expect(CompletionLength.short.maxWords == 1)
        #expect(CompletionLength.medium.maxWords == 4)   // "Medium (2–4 words)"
        #expect(CompletionLength.long.maxWords == 20)
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
