import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("TypeAhead").font(.largeTitle).bold()
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("All AI inference runs on-device. No data ever leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("About")
    }
}
