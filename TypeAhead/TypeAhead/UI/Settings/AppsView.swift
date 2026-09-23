import SwiftUI

/// UI-facing tri-state for the per-app completions override: mirrors `AppOverride
/// .completionsEnabled: Bool?` (nil = inherit the global toggle / legacy exclusion list).
private enum CompletionsChoice: String, CaseIterable, Identifiable {
    case inherit, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inherit: "Default"
        case .on:      "On"
        case .off:     "Off"
        }
    }
    init(_ value: Bool?) {
        switch value {
        case .some(true):  self = .on
        case .some(false): self = .off
        case .none:        self = .inherit
        }
    }
    var value: Bool? {
        switch self {
        case .inherit: nil
        case .on:      true
        case .off:     false
        }
    }
}

struct AppsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newBundleID = ""
    @State private var newSite = ""

    private var sortedApps: [RegisteredApp] {
        settings.appRegistry.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                if sortedApps.isEmpty {
                    Text("No apps registered yet. Apps you type in are added here automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedApps) { app in
                        AppRow(bundleID: app.bundleID)
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Apps are added here automatically the first time TypeAhead sees them. \u{201C}Default\u{201D} follows the global Completions toggle above and the legacy exclusions below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.siteRules.isEmpty {
                    Text("No website rules. Add a site to change suggestions there, e.g. turn them off on your bank.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.siteRules.keys.sorted(), id: \.self) { domain in
                        SiteRow(domain: domain)
                    }
                }
                HStack(spacing: 8) {
                    TextField("example.com", text: $newSite)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addSite() }
                    Button("Add") { addSite() }
                        .disabled(SiteRules.normalizedDomain(newSite) == nil)
                }
            } header: {
                Text("Websites")
            } footer: {
                Text("Rules for pages in Safari, Chrome, Arc, Firefox and other browsers. A site rule covers its subdomains and overrides the browser\u{2019}s own setting above. Only sites you add are stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if s.exceptionList.bundleIDs.isEmpty {
                    Text("No exceptions — completions appear in every app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(s.exceptionList.bundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                s.exceptionList.remove(bundleID: bundleID)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addBundleID() }
                    Button("Add") { addBundleID() }
                        .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Legacy Exclusions")
            } footer: {
                Text("The original all-or-nothing per-app exception list. An explicit \u{201C}On\u{201D} above overrides an exclusion here. Bundle IDs can be found via System Information or \u{2018}osascript -e id of app \"AppName\"\u{2019}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Apps")
    }

    private func addSite() {
        if settings.updateSiteRule(domain: newSite, { $0.completionsEnabled = false }) {
            newSite = ""
        }
    }

    private func addBundleID() {
        let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.exceptionList.isExcluded(bundleID: trimmed) else { return }
        settings.exceptionList.add(bundleID: trimmed)
        newBundleID = ""
    }
}

/// One row in the Apps list: name/bundleID, a completions Default/On/Off picker, the
/// "Disable Tab accept" / "Record typing history" / "Improve compatibility" toggles, and a
/// per-app style instruction field. All write through `AppSettings.updateOverride`.
private struct AppRow: View {
    @Environment(AppSettings.self) private var settings
    let bundleID: String

    private var app: RegisteredApp { settings.appRegistry[bundleID] ?? RegisteredApp(bundleID: bundleID, displayName: bundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName)
                    Text(bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: completionsBinding) {
                    ForEach(CompletionsChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack(spacing: 16) {
                Toggle("Disable Tab accept", isOn: tabKeyDisabledBinding)
                Toggle("Record typing history", isOn: recordHistoryBinding)
                    .disabled(!settings.storeInputHistory)
                    .help(settings.storeInputHistory
                          ? "Save words you accept in this app for personalization."
                          : "Turn on \u{201C}Collect inputs\u{201D} in Personalization first.")
                Toggle("Improve compatibility", isOn: compatibilityBinding)
                    .help("Insert by simulated typing and place suggestions using the screen, for apps where suggestions land in the wrong place or Tab doesn't insert.")
            }
            .font(.caption)

            TextField("Style instruction (e.g. \"Keep it terse and casual.\")", text: styleInstructionBinding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var completionsBinding: Binding<CompletionsChoice> {
        Binding(
            get: { CompletionsChoice(app.override.completionsEnabled) },
            set: { newChoice in mutate { $0.completionsEnabled = newChoice.value } }
        )
    }

    private var tabKeyDisabledBinding: Binding<Bool> {
        Binding(
            get: { app.override.tabKeyDisabled ?? false },
            set: { newValue in mutate { $0.tabKeyDisabled = newValue } }
        )
    }

    private var recordHistoryBinding: Binding<Bool> {
        Binding(
            get: { settings.storeInputHistory && (app.override.recordHistory ?? true) },
            // Store only the exception (off); "on" goes back to inheriting the global switch.
            set: { newValue in mutate { $0.recordHistory = newValue ? nil : false } }
        )
    }

    private var compatibilityBinding: Binding<Bool> {
        Binding(
            get: { app.override.compatibilityMode ?? false },
            set: { newValue in mutate { $0.compatibilityMode = newValue ? true : nil } }
        )
    }

    private var styleInstructionBinding: Binding<String> {
        Binding(
            get: { app.override.styleInstruction ?? "" },
            set: { newValue in mutate { $0.styleInstruction = newValue.isEmpty ? nil : newValue } }
        )
    }

    private func mutate(_ change: (inout AppOverride) -> Void) {
        settings.updateOverride(bundleID: bundleID, displayName: app.displayName, change)
    }
}

/// One website rule: domain, completions Default/On/Off, Tab-accept and history toggles, a style
/// instruction, and a remove button. Writes through `AppSettings.updateSiteRule`.
private struct SiteRow: View {
    @Environment(AppSettings.self) private var settings
    let domain: String

    private var rule: AppOverride { settings.siteRules[domain] ?? AppOverride() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(domain)
                Spacer()
                Picker("", selection: Binding(
                    get: { CompletionsChoice(rule.completionsEnabled) },
                    set: { choice in edit { $0.completionsEnabled = choice.value } }
                )) {
                    ForEach(CompletionsChoice.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
                Button {
                    settings.siteRules[domain] = nil
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Remove this website rule")
            }
            HStack(spacing: 16) {
                Toggle("Disable Tab accept", isOn: Binding(
                    get: { rule.tabKeyDisabled ?? false },
                    set: { value in edit { $0.tabKeyDisabled = value ? true : nil } }
                ))
                Toggle("Record typing history", isOn: Binding(
                    get: { settings.storeInputHistory && (rule.recordHistory ?? true) },
                    set: { value in edit { $0.recordHistory = value ? nil : false } }
                ))
                .disabled(!settings.storeInputHistory)
            }
            .font(.caption)
            TextField("Style instruction for this site", text: Binding(
                get: { rule.styleInstruction ?? "" },
                set: { value in edit { $0.styleInstruction = value.isEmpty ? nil : value } }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func edit(_ change: (inout AppOverride) -> Void) {
        settings.updateSiteRule(domain: domain, change)
    }
}
