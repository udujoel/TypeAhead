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
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ──────────────────────────────────────
                HStack(spacing: 14) {
                    Image(systemName: allReady ? "checkmark.circle.fill" : "gearshape.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(allReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(allReady ? "All Set!" : "Setup Required")
                            .font(.title2).bold()
                        Text(allReady
                             ? "TypeAhead is ready. Start typing in any app."
                             : "Complete the steps below to enable completions.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
                .padding(.bottom, 4)

                // ── Accessibility ───────────────────────────────
                RequirementRow(
                    title: "Accessibility Permission",
                    description: "Required to read and insert text in other apps.",
                    badge: accessibilityGranted ? .granted : .required
                ) {
                    if !accessibilityGranted {
                        Button("Grant Access") { openAccessibilitySettings() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }

                // ── Input Monitoring ────────────────────────────
                RequirementRow(
                    title: "Input Monitoring Permission",
                    description: "Required to detect keystrokes in other apps.",
                    badge: inputMonitoringGranted ? .granted : .required
                ) {
                    if !inputMonitoringGranted {
                        Button("Grant Access") { openInputMonitoringSettings() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }

                // ── Screen Recording ────────────────────────────
                RequirementRow(
                    title: "Screen Recording",
                    description: "Optional — for richer context-aware suggestions. Processed on-device, never stored.",
                    badge: screenRecordingGranted ? .granted : .optional
                ) {
                    if !screenRecordingGranted {
                        Button("Grant Access") { openScreenRecordingSettings() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }

                // ── On-Device Model ─────────────────────────────
                ModelDownloadRow(modelManager: modelManager, settings: settings)

                // ── Clipboard Context ───────────────────────────
                RequirementRow(
                    title: "Clipboard Context",
                    description: "Lets TypeAhead read your clipboard for more relevant suggestions.",
                    badge: settings.useClipboardContext ? .enabled : .disabled
                ) { EmptyView() }
            }
            .padding(28)
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

// MARK: - Model download row (live progress)

private struct ModelDownloadRow: View {
    let modelManager: ModelManager
    let settings: AppSettings

    private var activeConfig: ModelConfig {
        ModelConfig.all.first { $0.id == settings.activeModelID } ?? ModelConfig.defaultModel
    }

    var body: some View {
        let status = modelManager.status(for: activeConfig)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-Device Model")
                        .fontWeight(.medium)
                    Text(activeConfig.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                modelStatusBadge(status)
            }

            // Progress bar — only visible while downloading
            if case .downloading(let progress) = status {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                    Text(String(format: "%d%% — %.1f GB of %.1f GB",
                                Int(progress * 100),
                                activeConfig.fileSizeGB * progress,
                                activeConfig.fileSizeGB))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }

            // Download button — only when not yet started
            if status == .notDownloaded {
                Button("Download \(activeConfig.displayName)") {
                    Task { await modelManager.downloadAndActivate(config: activeConfig) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 10)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func modelStatusBadge(_ status: ModelStatus) -> some View {
        switch status {
        case .notDownloaded:
            Text("Not Downloaded")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .downloading(let p):
            Text("\(Int(p * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.blue)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Shared requirement row

private enum BadgeStyle {
    case granted, required, optional, enabled, disabled
    var label: String {
        switch self {
        case .granted: "Granted"; case .required: "Required"
        case .optional: "Optional"; case .enabled: "Enabled"; case .disabled: "Disabled"
        }
    }
    var color: Color {
        switch self {
        case .granted, .enabled: .green
        case .required: .orange
        case .optional, .disabled: .secondary
        }
    }
}

private struct RequirementRow<Trailing: View>: View {
    let title: String
    let description: String
    let badge: BadgeStyle
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 6) {
                Text(badge.label).font(.callout).foregroundStyle(badge.color)
                trailing()
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
