import SwiftUI

struct PersonalizationView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Typing History") {
                Toggle("Store Input History", isOn: $s.storeInputHistory)
            }
            Section("Word Choice") {
                VStack(alignment: .leading) {
                    Text("Personalization Strength: \(Int(s.personalizationStrength * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $s.personalizationStrength, in: 0...1)
                }
            }
            Section("Custom Instructions") {
                TextEditor(text: $s.customInstructions)
                    .frame(minHeight: 100)
                Text("Up to 500 words. Injected at the top of every prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Personalization")
    }
}
