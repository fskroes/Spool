import SwiftUI
import StripleCore
import StripleEngine

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, displays, rules, shortcuts, macSetup = "mac-setup", help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .displays: return "Displays"
        case .rules: return "App Rules"
        case .shortcuts: return "Shortcuts"
        case .macSetup: return "Mac Setup"
        case .help: return "Help"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .displays: return "display.2"
        case .rules: return "list.bullet.rectangle"
        case .shortcuts: return "keyboard"
        case .macSetup: return "checklist"
        case .help: return "questionmark.circle"
        }
    }
}

/// The settings window. Every control writes through `ConfigStore.update`, so there is no Save button.
struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: Engine
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: Binding(get: { app.tab }, set: { if let t = $0 { app.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            VStack(spacing: 0) {
                if let error = store.loadError {
                    ConfigErrorBanner(message: error)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    @ViewBuilder private var detail: some View {
        switch app.tab {
        case .general: GeneralTab(store: store, engine: engine)
        case .displays: DisplaysTab(store: store)
        case .rules: RulesTab(store: store)
        case .shortcuts: ShortcutsTab(store: store, recorder: app.recorder)
        case .macSetup: MacSetupTab(store: store)
        case .help: HelpTab(store: store)
        }
    }
}

struct ConfigErrorBanner: View {
    let message: String
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open File") { app.openConfigFile() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }
}
