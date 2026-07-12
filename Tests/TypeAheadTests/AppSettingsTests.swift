import Foundation
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

    @Test func defaultExclusionListContainsDeveloperTools() {
        let list = AppExceptionList.defaults
        #expect(list.isExcluded(bundleID: "com.apple.Terminal"))
        #expect(list.isExcluded(bundleID: "com.microsoft.VSCode"))
        #expect(list.isExcluded(bundleID: "com.apple.dt.Xcode"))
        #expect(list.isExcluded(bundleID: "com.googlecode.iterm2"))
    }

    @Test func exceptionListIsNotExcludedForUnknownApp() {
        let list = AppExceptionList.defaults
        #expect(!list.isExcluded(bundleID: "com.apple.TextEdit"))
        #expect(!list.isExcluded(bundleID: "com.example.unknown"))
    }

    @Test func exceptionListCodableRoundTrip() throws {
        var list = AppExceptionList.defaults
        list.add(bundleID: "com.custom.app")
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(AppExceptionList.self, from: data)
        #expect(decoded.isExcluded(bundleID: "com.agilebits.onepassword7"))
        #expect(decoded.isExcluded(bundleID: "com.custom.app"))
        #expect(!decoded.isExcluded(bundleID: "com.apple.TextEdit"))
    }

    @Test func settingsExceptionListStartsFromDefaults() {
        let settings = AppSettings()
        #expect(settings.exceptionList.isExcluded(bundleID: "com.apple.Terminal"))
        #expect(!settings.exceptionList.isExcluded(bundleID: "com.apple.TextEdit"))
    }

    @Test func bundleIDsReturnsEmptyForEmptyList() {
        let list = AppExceptionList()
        #expect(list.bundleIDs.isEmpty)
    }

    @Test func bundleIDsReturnsSortedList() {
        var list = AppExceptionList()
        list.add(bundleID: "com.z.app")
        list.add(bundleID: "com.a.app")
        list.add(bundleID: "com.m.app")
        #expect(list.bundleIDs == ["com.a.app", "com.m.app", "com.z.app"])
    }

    @Test func bundleIDsReflectsRemoval() {
        var list = AppExceptionList()
        list.add(bundleID: "com.example.one")
        list.add(bundleID: "com.example.two")
        list.remove(bundleID: "com.example.one")
        #expect(list.bundleIDs == ["com.example.two"])
    }

    @Test func bundleIDsDefaultsContainsKnownEntries() {
        let list = AppExceptionList.defaults
        let ids = list.bundleIDs
        #expect(ids.contains("com.apple.Terminal"))
        #expect(ids.contains("com.microsoft.VSCode"))
        #expect(ids.contains("com.agilebits.onepassword7"))
        #expect(ids == ids.sorted())
    }

    @Test func registerAppIfNeededAddsNewEntryWithNilOverride() {
        let settings = AppSettings()
        let bundleID = "com.test.registerAppIfNeededAddsNewEntryWithNilOverride"
        settings.registerAppIfNeeded(bundleID: bundleID, displayName: "Test App")
        let registered = settings.appRegistry[bundleID]
        #expect(registered?.displayName == "Test App")
        #expect(registered?.override.completionsEnabled == nil)
        #expect(registered?.override.tabKeyDisabled == nil)
    }

    @Test func registerAppIfNeededDoesNotOverwriteExistingEntry() {
        let settings = AppSettings()
        let bundleID = "com.test.registerAppIfNeededDoesNotOverwriteExistingEntry"
        settings.appRegistry[bundleID] = RegisteredApp(
            bundleID: bundleID,
            displayName: "Original",
            override: AppOverride(completionsEnabled: false)
        )
        settings.registerAppIfNeeded(bundleID: bundleID, displayName: "Renamed")
        #expect(settings.appRegistry[bundleID]?.displayName == "Original")
        #expect(settings.appRegistry[bundleID]?.override.completionsEnabled == false)
    }

    @Test func registeredAppCodableRoundTrip() throws {
        let app = RegisteredApp(
            bundleID: "com.test.registeredAppCodableRoundTrip",
            displayName: "Test",
            override: AppOverride(completionsEnabled: true, tabKeyDisabled: true, styleInstruction: "Casual.")
        )
        let data = try JSONEncoder().encode(app)
        let decoded = try JSONDecoder().decode(RegisteredApp.self, from: data)
        #expect(decoded == app)
    }

    @Test func passwordManagersArePreSeededWithCompletionsDisabled() {
        // The one-time seed migration runs against the real UserDefaults.standard the first
        // time any AppSettings is constructed on this machine, so a freshly-constructed
        // instance should already carry the seeded overrides.
        let settings = AppSettings()
        for bundleID in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"] {
            #expect(settings.appRegistry[bundleID]?.override.completionsEnabled == false, "expected \(bundleID) pre-seeded")
        }
    }
}
