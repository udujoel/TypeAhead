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
    /// Injection point so tests can point at an isolated `UserDefaults` suite instead of
    /// `.standard` — every didSet below writes through this instance rather than the
    /// hardcoded singleton, and every existing `AppSettings()` call site keeps working
    /// unchanged via the default argument.
    private let defaults: UserDefaults

    var completionsEnabled: Bool {
        didSet { defaults.set(completionsEnabled, forKey: Keys.completionsEnabled) }
    }
    var completionDelay: Double {
        didSet { defaults.set(completionDelay, forKey: Keys.completionDelay) }
    }
    var completionLength: CompletionLength {
        didSet { defaults.set(completionLength.rawValue, forKey: Keys.completionLength) }
    }
    var activeModelID: String {
        didSet { defaults.set(activeModelID, forKey: Keys.activeModelID) }
    }
    /// B6: whether a space follows the last word of an accepted suggestion (Cotypist's "Include
    /// trailing space after single-word completions"). See `AcceptPlan`.
    var addSpaceAfterAcceptedWord: Bool {
        didSet { defaults.set(addSpaceAfterAcceptedWord, forKey: Keys.addSpaceAfterAcceptedWord) }
    }
    /// Which English spelling to write and spell-check in (see `EnglishVariant`).
    var englishVariant: EnglishVariant {
        didSet { defaults.set(englishVariant.rawValue, forKey: Keys.englishVariant) }
    }
    /// B7: whether to suggest while there's text after the cursor on the same line.
    var midLineCompletionsEnabled: Bool {
        didSet { defaults.set(midLineCompletionsEnabled, forKey: Keys.midLineCompletionsEnabled) }
    }
    var storeInputHistory: Bool {
        didSet { defaults.set(storeInputHistory, forKey: Keys.storeInputHistory) }
    }
    var personalizationStrength: Double {
        didSet { defaults.set(personalizationStrength, forKey: Keys.personalizationStrength) }
    }
    var customInstructions: String {
        didSet { defaults.set(customInstructions, forKey: Keys.customInstructions) }
    }
    var useScreenshotContext: Bool {
        didSet { defaults.set(useScreenshotContext, forKey: Keys.useScreenshotContext) }
    }
    var useClipboardContext: Bool {
        didSet { defaults.set(useClipboardContext, forKey: Keys.useClipboardContext) }
    }
    var emojiSuggestionsEnabled: Bool {
        didSet { defaults.set(emojiSuggestionsEnabled, forKey: Keys.emojiSuggestionsEnabled) }
    }
    var exceptionList: AppExceptionList {
        didSet {
            if let data = try? JSONEncoder().encode(exceptionList) {
                defaults.set(data, forKey: Keys.exceptionList)
            }
        }
    }
    /// Per-app registry (bundleID → registered app + override), backing the "Apps" settings
    /// pane. Apps are auto-registered the first time completions run in them; entries here
    /// with a non-nil override take precedence over the legacy `exceptionList` (see
    /// `AppPolicyResolver`).
    var appRegistry: [String: RegisteredApp] {
        didSet {
            if let data = try? JSONEncoder().encode(appRegistry) {
                defaults.set(data, forKey: Keys.appRegistry)
            }
        }
    }

    init(defaults d: UserDefaults = .standard) {
        self.defaults = d
        completionsEnabled    = d.object(forKey: Keys.completionsEnabled)    as? Bool   ?? true
        completionDelay       = d.object(forKey: Keys.completionDelay)       as? Double ?? 0.12
        completionLength      = CompletionLength(rawValue: d.string(forKey: Keys.completionLength) ?? "") ?? .medium
        activeModelID         = d.string(forKey: Keys.activeModelID) ?? ModelConfig.defaultModel.id
        addSpaceAfterAcceptedWord = d.object(forKey: Keys.addSpaceAfterAcceptedWord) as? Bool ?? true
        midLineCompletionsEnabled = d.object(forKey: Keys.midLineCompletionsEnabled) as? Bool ?? true
        englishVariant = EnglishVariant(rawValue: d.string(forKey: Keys.englishVariant) ?? "") ?? .automatic
        storeInputHistory     = d.object(forKey: Keys.storeInputHistory)     as? Bool   ?? true
        personalizationStrength = d.object(forKey: Keys.personalizationStrength) as? Double ?? 0.5
        customInstructions    = d.string(forKey: Keys.customInstructions) ?? ""
        useScreenshotContext  = d.object(forKey: Keys.useScreenshotContext)  as? Bool   ?? true
        useClipboardContext   = d.object(forKey: Keys.useClipboardContext)   as? Bool   ?? true
        emojiSuggestionsEnabled = d.object(forKey: Keys.emojiSuggestionsEnabled) as? Bool ?? true
        if let data = d.data(forKey: Keys.exceptionList),
           let decoded = try? JSONDecoder().decode(AppExceptionList.self, from: data) {
            exceptionList = decoded
        } else {
            exceptionList = .defaults
        }
        if let data = d.data(forKey: Keys.appRegistry),
           let decoded = try? JSONDecoder().decode([String: RegisteredApp].self, from: data) {
            appRegistry = decoded
        } else {
            appRegistry = [:]
        }

        // The old v2 migration bumped the delay to 0.35s to avoid firing on every
        // keystroke. The pipeline now has a max-wait throttle, so a short delay is fine
        // and gives near-continuous suggestions. v3 brings existing users down off 0.35s.
        // Assigning `completionDelay` here runs inside `init`, before `self` is fully formed
        // for Swift's purposes — property observers don't fire on assignments made during
        // the initializer, so the `didSet` above never persists this write. Without an
        // explicit `d.set` here, the migrated value lives only in memory for this launch and
        // the old 0.35s value reloads from disk next time. Persist explicitly.
        if !d.bool(forKey: "didMigrateDelay_v3") {
            if completionDelay >= 0.25 {
                completionDelay = 0.18
                d.set(completionDelay, forKey: Keys.completionDelay)
            }
            d.set(true, forKey: "didMigrateDelay_v3")
        }

        // WP-8: with the KV-cache reuse bug fixed, a mid-typing fire is a cheap delta
        // prefill rather than a full rebuild, so a snappier default cadence is safe. v4
        // brings existing users down off the old 0.18 default to 0.12 — but only if they
        // never deliberately raised it. `>= 0.15` couldn't tell "still at the old default"
        // apart from "user deliberately chose something a bit slower than 0.15", so gate on
        // "untouched old default" instead: equal to 0.18 (within a small epsilon for Double
        // storage/round-trip noise) or absent entirely (a fresh install already initialized
        // `completionDelay` to the new 0.12 default above, which also satisfies "untouched").
        // A user who deliberately set 0.25 or 0.5 keeps it. Same didSet-in-init bug as v3
        // above applies here too — persist explicitly.
        if !d.bool(forKey: "didMigrateDelay_v4") {
            let isUntouchedOldDefault = d.object(forKey: Keys.completionDelay) == nil
                || abs(completionDelay - 0.18) < 0.001
            if isUntouchedOldDefault {
                completionDelay = 0.12
                d.set(completionDelay, forKey: Keys.completionDelay)
            }
            d.set(true, forKey: "didMigrateDelay_v4")
        }

        // One-time pre-seed: disable completions by default in password managers/finance
        // apps the exceptionList doesn't already cover as an explicit per-app override, so
        // ghost text never appears over a password/secret field even if the user later
        // edits or clears the legacy exception list.
        if !d.bool(forKey: "didSeedAppRegistry_v1") {
            let seeds: [(bundleID: String, displayName: String)] = [
                ("com.1password.1password", "1Password"),
                ("com.bitwarden.desktop", "Bitwarden"),
                ("com.apple.keychainaccess", "Keychain Access"),
                ("com.apple.Passwords", "Passwords"),
            ]
            for seed in seeds where appRegistry[seed.bundleID] == nil {
                appRegistry[seed.bundleID] = RegisteredApp(
                    bundleID: seed.bundleID,
                    displayName: seed.displayName,
                    override: AppOverride(completionsEnabled: false)
                )
            }
            d.set(true, forKey: "didSeedAppRegistry_v1")
        }
    }

    /// Auto-registers an app the first time completions run in it, so it shows up in the
    /// "Apps" settings pane. No-op if already registered. New entries start with a
    /// nil-fields override — pure inherited defaults — until the user sets one explicitly.
    func registerAppIfNeeded(bundleID: String, displayName: String) {
        guard appRegistry[bundleID] == nil else { return }
        appRegistry[bundleID] = RegisteredApp(bundleID: bundleID, displayName: displayName)
    }

    /// Edits one app's override, registering the app first if needed. The single write path for
    /// the Apps pane, the status menu's per-app item, and the ⌃⌥⌘` shortcut.
    func updateOverride(bundleID: String, displayName: String, _ edit: (inout AppOverride) -> Void) {
        var app = appRegistry[bundleID] ?? RegisteredApp(bundleID: bundleID, displayName: displayName)
        edit(&app.override)
        appRegistry[bundleID] = app
    }

    private enum Keys {
        static let completionsEnabled     = "completionsEnabled"
        static let completionDelay        = "completionDelay"
        static let completionLength       = "completionLength"
        static let activeModelID          = "activeModelID"
        static let addSpaceAfterAcceptedWord = "addSpaceAfterAcceptedWord"
        static let midLineCompletionsEnabled = "midLineCompletionsEnabled"
        static let englishVariant = "englishVariant"
        static let storeInputHistory      = "storeInputHistory"
        static let personalizationStrength = "personalizationStrength"
        static let customInstructions     = "customInstructions"
        static let useScreenshotContext   = "useScreenshotContext"
        static let useClipboardContext    = "useClipboardContext"
        static let emojiSuggestionsEnabled = "emojiSuggestionsEnabled"
        static let exceptionList            = "exceptionList"
        static let appRegistry              = "appRegistry"
    }
}
