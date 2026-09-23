import SwiftUI

struct GeneralView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @State private var loginItem = LoginItemController.shared

    private var recommendedModel: ModelConfig {
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        return ModelConfig.recommended(availableRAMGB: ramGB)
    }

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
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Trigger Delay")
                        Spacer()
                        Text("\(Int(s.completionDelay * 1000)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $s.completionDelay, in: 0.10...0.60, step: 0.05)
                    Text("Lower = faster suggestions, higher = fewer interruptions while typing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Toggle("Mid-line Completions", isOn: $s.midLineCompletionsEnabled)
                Text("Suggest even when there's text after the cursor on the same line.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Add a Space After Accepted Words", isOn: $s.addSpaceAfterAcceptedWord)
                LabeledContent("Accept next word", value: "Tab  or  ⌥→")
                LabeledContent("Accept whole suggestion", value: "⇧Tab")
                LabeledContent("Type a normal Tab", value: "⌥Tab")
                LabeledContent("Dismiss and pause briefly", value: "Esc")
                LabeledContent("Turn on/off for current app", value: "⌃⌥⌘`")
                LabeledContent("Open the TypeAhead menu", value: "⌃⌥⌘T")
            } header: {
                Text("Accepting Suggestions")
            }

            Section {
                ForEach(ModelConfig.all) { config in
                    ModelRow(
                        config: config,
                        modelManager: modelManager,
                        isRecommended: config.id == recommendedModel.id
                    )
                }
            } header: {
                HStack {
                    Text("AI Model")
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(
                            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("models")
                        )
                    } label: {
                        Label("Model Files", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Use Clipboard Context", isOn: $s.useClipboardContext)
                Toggle("Use Screen Context", isOn: $s.useScreenshotContext)
            } header: {
                Text("Context")
            } footer: {
                Text("Screen Context reads on-screen text with on-device OCR to sharpen suggestions. Everything stays on this Mac — nothing is ever uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItem.isEnabled || loginItem.needsApproval },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    HStack {
                        Text("Allow TypeAhead in System Settings → General → Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text("Couldn't change the login item: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Enable Emoji Suggestions", isOn: $s.emojiSuggestionsEnabled)
            } header: {
                Text("App")
            } footer: {
                Text("Per-app controls — including exceptions — moved to the Apps section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { loginItem.refresh() }
    }
}

// MARK: - Per-model row

private struct ModelRow: View {
    let config: ModelConfig
    let modelManager: ModelManager
    let isRecommended: Bool

    @State private var isActioning = false

    var body: some View {
        let status = modelManager.status(for: config)

        HStack(spacing: 10) {
            // Left: name + size + recommended badge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(config.displayName)
                        .fontWeight(status == .active ? .semibold : .regular)
                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text(String(format: "%.1f GB  ·  %d GB RAM minimum", config.fileSizeGB, config.minRAMGB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // WP-5 (P1): E4B is no longer auto-recommended (see ModelConfig.gemma4E4B) — it
                // costs ~2x per-token vs E2B, which matters for a latency-sensitive typeahead.
                // Still user-selectable; this just sets expectations for who should pick it.
                if config.id == ModelConfig.gemma4E4B.id {
                    Text("Higher quality, slower — best on M-series Pro/Max")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Right: status + action
            statusView(status)
            actionButton(status)
                .disabled(isActioning || status == .loading || status == .downloading(0))
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
                    .frame(width: 72)
                Text("\(Int(p * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func actionButton(_ status: ModelStatus) -> some View {
        switch status {
        case .notDownloaded:
            if ModelManager.isModelCached(repoId: config.huggingFaceRepo) {
                Button("Activate") {
                    isActioning = true
                    Task {
                        await modelManager.downloadAndActivate(config: config)
                        isActioning = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Download") {
                    isActioning = true
                    Task {
                        await modelManager.downloadAndActivate(config: config)
                        isActioning = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .active, .downloading, .loading:
            EmptyView()
        }
    }
}
