import Combine
import SwiftUI
import ApplicationServices

struct SetupView: View {
    @Environment(AppSettings.self) private var settings

    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var screenRecordingGranted = false
    @State private var modelLoaded = false

    private var allReady: Bool {
        accessibilityGranted && inputMonitoringGranted && modelLoaded
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ── Header ─────────────────────────────────────
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
                .padding(.bottom, 8)

                // ── Accessibility ───────────────────────────────
                RequirementRow(
                    title: "Accessibility Permission",
                    description: "Required to read and insert text in other apps.",
                    badge: accessibilityGranted ? .granted : .required
                ) {
                    if !accessibilityGranted {
                        Button("Grant Access") { openAccessibilitySettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                // ── Input Monitoring ────────────────────────────
                RequirementRow(
                    title: "Input Monitoring Permission",
                    description: "Required to detect keystrokes in other apps so completions can trigger while you type.",
                    badge: inputMonitoringGranted ? .granted : .required
                ) {
                    if !inputMonitoringGranted {
                        Button("Grant Access") { openInputMonitoringSettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                // ── Screen Recording ────────────────────────────
                RequirementRow(
                    title: "Screen Recording Permission",
                    description: "Recommended for richer context-aware suggestions. Screenshots are processed on-device and never stored.",
                    badge: screenRecordingGranted ? .granted : .optional
                ) {
                    if !screenRecordingGranted {
                        Button("Grant Access") { openScreenRecordingSettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                // ── On-Device MLX Model ─────────────────────────
                RequirementRow(
                    title: "On-Device Model",
                    description: modelLoaded
                        ? "MLX model loaded and ready. All inference runs on-device."
                        : "Model is downloading in the background on first launch. Check General → Model for status.",
                    badge: modelLoaded ? .granted : .required
                ) { EmptyView() }

                // ── Clipboard Context ───────────────────────────
                RequirementRow(
                    title: "Clipboard Context",
                    description: "Helps TypeAhead make more relevant suggestions based on what you've copied.",
                    badge: settings.useClipboardContext ? .enabled : .disabled
                ) { EmptyView() }
            }
            .padding(32)
        }
        .onAppear { checkPermissions() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
    }

    // MARK: - Helpers

    private func checkPermissions() {
        accessibilityGranted   = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        modelLoaded            = AppDependencies.shared.inferenceEngine.isLoaded
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        )
    }

    private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
    }
}

// MARK: - Reusable requirement card

private enum BadgeStyle {
    case granted, required, optional, enabled, disabled

    var label: String {
        switch self {
        case .granted:  "Granted"
        case .required: "Required"
        case .optional: "Optional"
        case .enabled:  "Enabled"
        case .disabled: "Disabled"
        }
    }

    var color: Color {
        switch self {
        case .granted, .enabled:  .green
        case .required:           .orange
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
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 6) {
                Text(badge.label)
                    .font(.callout)
                    .foregroundStyle(badge.color)
                trailing()
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
