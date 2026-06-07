import Foundation
import Observation

enum CompletionLength: String, CaseIterable, Sendable {
    case short, medium, long
    /// How many tokens the model may generate (caps compute/latency). Kept comfortably
    /// above maxWords so the model isn't cut off before it produces real words (it often
    /// emits a newline or two first); the displayed result is then capped by maxWords.
    var maxTokens: Int {
        switch self { case .short: 16; case .medium: 32; case .long: 64 }
    }
    /// How many words of the result are actually shown (enforces the label below).
    /// 0 would mean "no cap"; we always cap here.
    var maxWords: Int {
        switch self { case .short: 1; case .medium: 4; case .long: 20 }
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
        completionDelay       = d.object(forKey: Keys.completionDelay)       as? Double ?? 0.18
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

        // The old v2 migration bumped the delay to 0.35s to avoid firing on every
        // keystroke. The pipeline now has a max-wait throttle, so a short delay is fine
        // and gives near-continuous suggestions. v3 brings existing users down off 0.35s.
        if !d.bool(forKey: "didMigrateDelay_v3") {
            if completionDelay >= 0.25 { completionDelay = 0.18 }
            d.set(true, forKey: "didMigrateDelay_v3")
        }
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
