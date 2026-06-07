import SwiftUI

struct PersonalizationView: View {
    @Environment(AppSettings.self) private var settings
    /// Live count of stored history records — loaded once on appear, updated after delete.
    @State private var recordCount: Int = 0
    @State private var showDeleteConfirmation = false

    var body: some View {
        @Bindable var s = settings
        Form {

            // MARK: - Typing History

            Section {
                Toggle("Collect inputs for personalization", isOn: $s.storeInputHistory)
                    .onChange(of: s.storeInputHistory) { _, _ in
                        Task { await refreshCount() }
                    }

                Text("""
                    TypeAhead can record words you accept to improve future suggestions for you. \
                    All collected data is encrypted and stored locally on your Mac — nothing is \
                    sent anywhere.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Typing History")
            }

            // MARK: - Existing data / Delete

            Section {
                HStack {
                    if recordCount == 0 {
                        Text("No inputs collected yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(recordCount) accepted word\(recordCount == 1 ? "" : "s") stored.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete All…", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(recordCount == 0)
                    .confirmationDialog(
                        "Delete all \(recordCount) stored words?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete All", role: .destructive) {
                            Task { await deleteHistory() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes your personalization history. Suggestions will no longer reflect your past word choices.")
                    }
                }
            } header: {
                Text("Existing Data")
            }

            // MARK: - Word choice slider

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Off")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $s.personalizationStrength, in: 0...1)
                            .disabled(!s.storeInputHistory)
                        Text("Max")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Uses your typing history to slightly favor words and phrases you prefer. Has no effect if Collect inputs is off.")
                        .font(.caption)
                        .foregroundStyle(s.storeInputHistory ? .secondary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Personalize Word Choice")
            }

            // MARK: - Custom instructions

            Section {
                ZStack(alignment: .topLeading) {
                    if s.customInstructions.isEmpty {
                        Text(#"e.g. "My name is Joel. I write in UK English. Prefer a friendly, concise, professional tone.""#)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $s.customInstructions)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                }

                Text("Customize how TypeAhead completes your text. Add your name, occupation, preferred style, or language. A few sentences work best — brevity keeps suggestions fast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Custom AI Instructions")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Personalization")
        .task { await refreshCount() }
    }

    private func refreshCount() async {
        // AppDependencies.shared is @MainActor and we're already on MainActor (SwiftUI),
        // so this is a direct call — no actor hop needed.
        recordCount = await AppDependencies.shared.historyStore.recordCount()
    }

    private func deleteHistory() async {
        try? AppDependencies.shared.historyStore.deleteAll()
        await refreshCount()
    }
}
