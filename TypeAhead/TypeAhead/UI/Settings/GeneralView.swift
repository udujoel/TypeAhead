import SwiftUI

struct GeneralView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Completions") {
                Toggle("Enable Completions", isOn: $s.completionsEnabled)
                Picker("Completion Length", selection: $s.completionLength) {
                    ForEach(CompletionLength.allCases, id: \.self) { length in
                        Text(length.displayName).tag(length)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Trigger Delay: \(Int(s.completionDelay * 1000))ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $s.completionDelay, in: 0.05...0.5, step: 0.01)
                }
                Toggle("Show in All Apps", isOn: $s.showInAllApps)
            }
            Section("Model") {
                Picker("Active Model", selection: $s.activeModelID) {
                    ForEach(ModelConfig.all) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            }
            Section("Context") {
                Toggle("Use Screenshot Context", isOn: $s.useScreenshotContext)
                Toggle("Use Clipboard Context", isOn: $s.useClipboardContext)
            }
            Section("App") {
                Toggle("Launch at Login", isOn: $s.launchAtLogin)
                Toggle("Emoji Suggestions", isOn: $s.emojiSuggestionsEnabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
