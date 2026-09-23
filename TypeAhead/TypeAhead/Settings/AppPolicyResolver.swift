import Foundation

/// A user-configured per-app override. Any `nil` field means "inherit the default" —
/// only explicitly-set fields take precedence over the global toggle / legacy exclusion list.
struct AppOverride: Sendable, Codable, Equatable {
    var completionsEnabled: Bool?
    var tabKeyDisabled: Bool?
    var styleInstruction: String?
    /// Whether accepted words in this app may be recorded to typing history. Can only turn
    /// recording OFF for an app — the global "Collect inputs" toggle is the privacy master switch.
    var recordHistory: Bool?
    /// "Improve compatibility": insert via synthesized keystrokes and treat the AX caret rect as
    /// unreliable (Vision/mirror placement) — the user-editable twin of `AppInsertionPolicy`.
    var compatibilityMode: Bool?

    init(
        completionsEnabled: Bool? = nil,
        tabKeyDisabled: Bool? = nil,
        styleInstruction: String? = nil,
        recordHistory: Bool? = nil,
        compatibilityMode: Bool? = nil
    ) {
        self.completionsEnabled = completionsEnabled
        self.tabKeyDisabled = tabKeyDisabled
        self.styleInstruction = styleInstruction
        self.recordHistory = recordHistory
        self.compatibilityMode = compatibilityMode
    }
}

/// The effective policy for a given app, after resolving global settings, the legacy
/// exclusion list, and any explicit per-app override.
struct ResolvedPolicy: Sendable, Equatable {
    let completionsEnabled: Bool
    let tabKeyDisabled: Bool
    let styleInstruction: String?
    let recordHistory: Bool
    let compatibilityMode: Bool
}

/// An app the user has typed in, tracked for the "Apps" settings pane. Auto-registered the
/// first time `runCompletion` sees a new bundle ID (with a nil-fields override, i.e. pure
/// inherited defaults); the user can then set an explicit override for it in the UI.
struct RegisteredApp: Sendable, Codable, Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    var displayName: String
    var override: AppOverride

    init(bundleID: String, displayName: String, override: AppOverride = AppOverride()) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.override = override
    }
}

/// Computes the effective per-app policy with a clear precedence:
/// 1. The global toggles are master switches — global completions off means off everywhere,
///    global "Collect inputs" off means nothing is recorded anywhere.
/// 2. Under an enabled global switch, an explicit per-app override wins over the legacy
///    exclusion list (so a user can re-enable one excluded app).
/// Pure logic — no AppSettings/AX dependency.
enum AppPolicyResolver {
    static func resolve(
        globalCompletionsEnabled: Bool,
        excludedByList: Bool,
        override: AppOverride?,
        globalRecordHistory: Bool = true
    ) -> ResolvedPolicy {
        let perAppCompletionsEnabled = perAppCompletionsEnabled(excludedByList: excludedByList, override: override)
        return ResolvedPolicy(
            completionsEnabled: globalCompletionsEnabled && perAppCompletionsEnabled,
            tabKeyDisabled: override?.tabKeyDisabled ?? false,
            styleInstruction: override?.styleInstruction,
            recordHistory: globalRecordHistory && (override?.recordHistory ?? true),
            compatibilityMode: override?.compatibilityMode ?? false
        )
    }

    /// Whether this app is switched on in its own right, ignoring the global master switch — what
    /// the status menu's "Turn Off/On Suggestions in ⟨App⟩" item and the ⌃⌥⌘` shortcut flip.
    static func perAppCompletionsEnabled(excludedByList: Bool, override: AppOverride?) -> Bool {
        override?.completionsEnabled ?? !excludedByList
    }
}
