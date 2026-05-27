import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case setup, general, personalization, statistics, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .setup:            "Setup"
        case .general:          "General"
        case .personalization:  "Personalization"
        case .statistics:       "Statistics"
        case .about:            "About"
        }
    }
    var icon: String {
        switch self {
        case .setup:            "checkmark.shield"
        case .general:          "slider.horizontal.3"
        case .personalization:  "person.crop.circle"
        case .statistics:       "chart.bar"
        case .about:            "info.circle"
        }
    }
}

struct SettingsWindow: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selectedSection {
                case .setup:            SetupView()
                case .general:          GeneralView()
                case .personalization:  PersonalizationView()
                case .statistics:       StatisticsView()
                case .about:            AboutView()
                }
            }
            .frame(minWidth: 480, minHeight: 400)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}
