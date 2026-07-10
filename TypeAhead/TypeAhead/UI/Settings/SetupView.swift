import Combine
import SwiftUI
import ApplicationServices

struct SetupView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager

    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var screenRecordingGranted = false

    private var allReady: Bool {
        accessibilityGranted && inputMonitoringGranted && modelManager.isAnyModelActive
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Hero header ─────────────────────────────────
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(allReady ? Color.green.opacity(0.15) : Color.orange.opacity(0.12))
                            .frame(width: 56, height: 56)
                        Image(systemName: allReady ? "checkmark.circle.fill" : "sparkles")
                            .font(.system(size: 28))
                            .foregroundStyle(allReady ? .green : .orange)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(allReady ? "You're all set!" : "Let's get started")
                            .font(.title2).bold()
                        Text(allReady
                             ? "TypeAhead is active. Start typing in any app."
                             : "A few quick steps to enable AI completions.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 20)

                // ── Steps ────────────────────────────────────────
                VStack(spacing: 12) {

                    SetupStepRow(
                        step: 1,
                        title: "Accessibility Access",
                        description: "Lets TypeAhead read and insert text in other apps.",
                        isComplete: accessibilityGranted,
                        isRequired: true
                    ) {
                        if !accessibilityGranted {
                            Button("Open Settings") { openAccessibilitySettings() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }

                    SetupStepRow(
                        step: 2,
                        title: "Input Monitoring",
                        description: "Lets TypeAhead detect when you're typing.",
                        isComplete: inputMonitoringGranted,
                        isRequired: true
                    ) {
                        if !inputMonitoringGranted {
                            Button("Open Settings") { openInputMonitoringSettings() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }

                    SetupStepRow(
                        step: 3,
                        title: "Screen Recording",
                        description: "Optional — powers Screen Context, which reads on-screen text for richer suggestions. Processed on-device, never uploaded. (macOS calls this permission \u{201C}Screen Recording.\u{201D})",
                        isComplete: screenRecordingGranted,
                        isRequired: false
                    ) {
                        if !screenRecordingGranted {
                            Button("Open Settings") { openScreenRecordingSettings() }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }

                    ModelDownloadRow(modelManager: modelManager, settings: settings)
                }

                // ── Tip ──────────────────────────────────────────
                if allReady {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                        Text("Start typing anywhere — suggestions appear automatically. Press **Tab** to accept.")
                            .font(.callout)
                    }
                    .padding(14)
                    .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 20)
                }
            }
            .padding(24)
        }
        .onAppear { checkPermissions() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        accessibilityGranted   = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

// MARK: - Step row

private struct SetupStepRow<Trailing: View>: View {
    let step: Int
    let title: String
    let description: String
    let isComplete: Bool
    let isRequired: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Step circle
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : Color.secondary.opacity(0.15))
                    .frame(width: 30, height: 30)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if !isRequired {
                        Text("Optional")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            trailing()
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Model download row

private struct ModelDownloadRow: View {
    let modelManager: ModelManager
    let settings: AppSettings

    private var activeConfig: ModelConfig {
        ModelConfig.all.first { $0.id == settings.activeModelID } ?? ModelConfig.defaultModel
    }

    var body: some View {
        let status = modelManager.status(for: activeConfig)

        HStack(alignment: .top, spacing: 14) {
            // Step circle
            ZStack {
                Circle()
                    .fill(status == .active ? Color.green : Color.secondary.opacity(0.15))
                    .frame(width: 30, height: 30)
                if status == .active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("4")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("AI Model").fontWeight(.medium)
                    Text(activeConfig.displayName)
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(.blue)
                }
                Text("Runs entirely on your device — no internet needed for completions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Progress bar during download
                if case .downloading(let progress) = status {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        Text(String(format: "Downloading… %.0f%%  (%.1f / %.1f GB)",
                                    progress * 100,
                                    activeConfig.fileSizeGB * progress,
                                    activeConfig.fileSizeGB))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if case .loading = status {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading model into memory…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if status == .notDownloaded {
                if ModelManager.isModelCached(repoId: activeConfig.huggingFaceRepo) {
                    Button("Activate") {
                        Task { await modelManager.downloadAndActivate(config: activeConfig) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Download") {
                        Task { await modelManager.downloadAndActivate(config: activeConfig) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
