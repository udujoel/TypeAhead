import SwiftUI

struct GeneralView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager

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
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $s.completionDelay, in: 0.05...0.5, step: 0.01)
                }
                Toggle("Show in All Apps", isOn: $s.showInAllApps)
            }

            Section("Model") {
                ForEach(ModelConfig.all) { config in
                    ModelRow(config: config, modelManager: modelManager)
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

// MARK: - Per-model row

private struct ModelRow: View {
    let config: ModelConfig
    let modelManager: ModelManager

    @State private var isActioning = false

    var body: some View {
        let status = modelManager.status(for: config)

        HStack(spacing: 12) {
            // Model name + size
            VStack(alignment: .leading, spacing: 2) {
                Text(config.displayName)
                    .fontWeight(status == .active ? .semibold : .regular)
                Text("\(String(format: "%.1f", config.fileSizeGB)) GB")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            // Status indicator
            statusView(status)

            // Action button
            actionButton(status)
                .disabled(isActioning || status == .loading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusView(_ status: ModelStatus) -> some View {
        switch status {
        case .notDownloaded:
            EmptyView()
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("\(Int(p * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Loading").font(.caption).foregroundStyle(.secondary)
            }
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func actionButton(_ status: ModelStatus) -> some View {
        switch status {
        case .notDownloaded:
            Button("Download") {
                isActioning = true
                Task {
                    await modelManager.downloadAndActivate(config: config)
                    isActioning = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .active, .downloading, .loading:
            // No button when already active or in progress
            EmptyView()
        }
    }
}
