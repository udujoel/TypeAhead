import Foundation

/// A user-configured per-app override. Any `nil` field means "inherit the default" —
/// only explicitly-set fields take precedence over the global toggle / legacy exclusion list.
struct AppOverride: Sendable, Codable, Equatable {
    var completionsEnabled: Bool?
    var tabKeyDisabled: Bool?
    var styleInstruction: String?

    init(completionsEnabled: Bool? = nil, tabKeyDisabled: Bool? = nil, styleInstruction: String? = nil) {
        self.completionsEnabled = completionsEnabled
        self.tabKeyDisabled = tabKeyDisabled
        self.styleInstruction = styleInstruction
    }
}

/// The effective policy for a given app, after resolving global settings, the legacy
/// exclusion list, and any explicit per-app override.
struct ResolvedPolicy: Sendable, Equatable {
    let completionsEnabled: Bool
    let tabKeyDisabled: Bool
    let styleInstruction: String?
}

/// Computes the effective per-app policy from three sources with a clear precedence:
/// an explicit per-app override wins over the legacy exclusion list, which together with
/// the global toggle forms the inherited default. Pure logic — no AppSettings/AX dependency.
enum AppPolicyResolver {
    static func resolve(globalCompletionsEnabled: Bool, excludedByList: Bool, override: AppOverride?) -> ResolvedPolicy {
        let inheritedCompletionsEnabled = globalCompletionsEnabled && !excludedByList
        let completionsEnabled = override?.completionsEnabled ?? inheritedCompletionsEnabled
        let tabKeyDisabled = override?.tabKeyDisabled ?? false
        let styleInstruction = override?.styleInstruction
        return ResolvedPolicy(
            completionsEnabled: completionsEnabled,
            tabKeyDisabled: tabKeyDisabled,
            styleInstruction: styleInstruction
        )
    }
}
