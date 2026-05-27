import Foundation
import Observation

enum CompletionLength: String, CaseIterable, Sendable {
    case short, medium, long
    var maxTokens: Int {
        switch self { case .short: 20; case .medium: 40; case .long: 80 }
    }
    var displayName: String {
        switch self {
        case .short: "Short (1 word)"
        case .medium: "Medium (2–4 words)"
        case .long: "Long (full sentence)"
        }
    }
}

@Observable
final class AppSettings {
    var completionsEnabled: Bool {
        didSet { UserDefaults.standard.set(completionsEnabled, forKey: Keys.completionsEnabled) }
    }
    var completionDelay: Double {
        didSet { UserDefaults.standard.set(completionDelay, forKey: Keys.completionDelay) }
    }
    var completionLength: CompletionLength {
        didSet { UserDefaults.standard.set(completionLength.rawValue, forKey: Keys.completionLength) }
    }
    var activeModelID: String {
        didSet { UserDefaults.standard.set(activeModelID, forKey: Keys.activeModelID) }
    }
    var showInAllApps: Bool {
        didSet { UserDefaults.standard.set(showInAllApps, forKey: Keys.showInAllApps) }
    }
    var storeInputHistory: Bool {
        didSet { UserDefaults.standard.set(storeInputHistory, forKey: Keys.storeInputHistory) }
    }
    var personalizationStrength: Double {
        didSet { UserDefaults.standard.set(personalizationStrength, forKey: Keys.personalizationStrength) }
    }
    var customInstructions: String {
        didSet { UserDefaults.standard.set(customInstructions, forKey: Keys.customInstructions) }
    }
    var useScreenshotContext: Bool {
        didSet { UserDefaults.standard.set(useScreenshotContext, forKey: Keys.useScreenshotContext) }
    }
    var useClipboardContext: Bool {
        didSet { UserDefaults.standard.set(useClipboardContext, forKey: Keys.useClipboardContext) }
    }
    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    var emojiSuggestionsEnabled: Bool {
        didSet { UserDefaults.standard.set(emojiSuggestionsEnabled, forKey: Keys.emojiSuggestionsEnabled) }
    }

    init() {
        let d = UserDefaults.standard
        completionsEnabled    = d.object(forKey: Keys.completionsEnabled)    as? Bool   ?? true
        completionDelay       = d.object(forKey: Keys.completionDelay)       as? Double ?? 0.12
        completionLength      = CompletionLength(rawValue: d.string(forKey: Keys.completionLength) ?? "") ?? .medium
        activeModelID         = d.string(forKey: Keys.activeModelID) ?? ModelConfig.defaultModel.id
        showInAllApps         = d.object(forKey: Keys.showInAllApps)         as? Bool   ?? true
        storeInputHistory     = d.object(forKey: Keys.storeInputHistory)     as? Bool   ?? true
        personalizationStrength = d.object(forKey: Keys.personalizationStrength) as? Double ?? 0.5
        customInstructions    = d.string(forKey: Keys.customInstructions) ?? ""
        useScreenshotContext  = d.object(forKey: Keys.useScreenshotContext)  as? Bool   ?? true
        useClipboardContext   = d.object(forKey: Keys.useClipboardContext)   as? Bool   ?? true
        launchAtLogin         = d.object(forKey: Keys.launchAtLogin)         as? Bool   ?? true
        emojiSuggestionsEnabled = d.object(forKey: Keys.emojiSuggestionsEnabled) as? Bool ?? true
    }

    private enum Keys {
        static let completionsEnabled     = "completionsEnabled"
        static let completionDelay        = "completionDelay"
        static let completionLength       = "completionLength"
        static let activeModelID          = "activeModelID"
        static let showInAllApps          = "showInAllApps"
        static let storeInputHistory      = "storeInputHistory"
        static let personalizationStrength = "personalizationStrength"
        static let customInstructions     = "customInstructions"
        static let useScreenshotContext   = "useScreenshotContext"
        static let useClipboardContext    = "useClipboardContext"
        static let launchAtLogin          = "launchAtLogin"
        static let emojiSuggestionsEnabled = "emojiSuggestionsEnabled"
    }
}
