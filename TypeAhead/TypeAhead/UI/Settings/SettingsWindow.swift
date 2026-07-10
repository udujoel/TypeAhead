import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case setup, general, apps, personalization, statistics, diagnostics, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .setup:            "Setup"
        case .general:          "General"
        case .apps:              "Apps"
        case .personalization:  "Personalization"
        case .statistics:       "Statistics"
        case .diagnostics:      "Diagnostics"
        case .about:            "About"
        }
    }
    var icon: String {
        switch self {
        case .setup:            "checkmark.shield.fill"
        case .general:          "slider.horizontal.3"
        case .apps:              "app.badge.checkmark.fill"
        case .personalization:  "person.crop.circle.fill"
        case .statistics:       "chart.bar.fill"
        case .diagnostics:      "wrench.and.screwdriver.fill"
        case .about:            "info.circle.fill"
        }
    }
    var iconColor: Color {
        switch self {
        case .setup:            .green
        case .general:          .blue
        case .apps:              .indigo
        case .personalization:  .purple
        case .statistics:       .orange
        case .diagnostics:      .teal
        case .about:            .gray
        }
    }
}

struct SettingsWindow: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedSection: SettingsSection = .setup

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                HStack(spacing: 10) {
                    Image(systemName: section.icon)
                        .foregroundStyle(section.iconColor)
                        .frame(width: 20)
                    Text(section.label)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190)
        } detail: {
            Group {
                switch selectedSection {
                case .setup:            SetupView()
                case .general:          GeneralView()
                case .apps:              AppsView()
                case .personalization:  PersonalizationView()
                case .statistics:       StatisticsView()
                case .diagnostics:      DiagnosticsView()
                case .about:            AboutView()
                }
            }
            .frame(minWidth: 500, minHeight: 420)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}
