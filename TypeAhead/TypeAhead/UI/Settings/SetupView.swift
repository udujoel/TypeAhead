import SwiftUI
import ApplicationServices

struct SetupView: View {
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Setup").font(.largeTitle).bold()

                permissionRow(
                    title: "Accessibility Permission",
                    subtitle: "Required. Allows TypeAhead to read and write text in any app.",
                    granted: accessibilityGranted,
                    action: openAccessibilitySettings
                )
                permissionRow(
                    title: "Screen Recording",
                    subtitle: "Recommended. Captures the active window for richer context. Never stored.",
                    granted: screenRecordingGranted,
                    action: openScreenRecordingSettings
                )
            }
            .padding(32)
        }
        .navigationTitle("Setup")
        .onAppear { checkPermissions() }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant Access", action: action)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func checkPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
