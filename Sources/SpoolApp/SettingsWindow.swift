import SwiftUI
import SpoolCore
import SpoolEngine

/// A page of the settings window. The raw value is the page in `spool://settings/<page>`.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, layout, appearance, trackpad, displays, rules, shortcuts, macSetup = "mac-setup", help

    var id: String { rawValue }

    /// The sidebar, in groups. Every page is in exactly one group.
    static let sidebarGroups: [[SettingsTab]] = [
        [.general, .layout, .appearance, .trackpad, .displays],
        [.rules, .shortcuts],
        [.macSetup, .help],
    ]

    var title: String {
        switch self {
        case .general: return "General"
        case .layout: return "Layout"
        case .appearance: return "Appearance"
        case .trackpad: return "Mouse & Trackpad"
        case .displays: return "Displays"
        case .rules: return "App Rules"
        case .shortcuts: return "Shortcuts"
        case .macSetup: return "Mac Setup"
        case .help: return "Help"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .layout: return "rectangle.split.3x1.fill"
        case .appearance: return "paintpalette.fill"
        case .trackpad: return "hand.point.up.left.fill"
        case .displays: return "display.2"
        case .rules: return "list.bullet.rectangle.fill"
        case .shortcuts: return "keyboard.fill"
        case .macSetup: return "checklist"
        case .help: return "questionmark"
        }
    }

    /// The colour of the icon tile in the sidebar, as in System Settings.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .layout: return .blue
        case .appearance: return .purple
        case .trackpad: return .orange
        case .displays: return .teal
        case .rules: return .indigo
        case .shortcuts: return .pink
        case .macSetup: return .green
        case .help: return .blue
        }
    }
}

/// The left side of the settings window.
struct SettingsSidebar: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        List(selection: Binding(get: { app.tab }, set: { if let t = $0 { app.tab = t } })) {
            ForEach(SettingsTab.sidebarGroups.indices, id: \.self) { i in
                Section {
                    ForEach(SettingsTab.sidebarGroups[i]) { tab in
                        Label { Text(tab.title) } icon: { SettingsIcon(tab: tab) }
                            .tag(tab)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A white symbol on a coloured rounded square.
struct SettingsIcon: View {
    let tab: SettingsTab

    var body: some View {
        Image(systemName: tab.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tab.tint.gradient))
            .accessibilityHidden(true)
    }
}

/// The right side of the settings window. Every control writes through `ConfigStore.update`, so there is no
/// Save button. The page title is the window title, above this pane.
struct SettingsDetail: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: Engine
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError {
                ConfigErrorBanner(message: error, isProblem: store.hasProblem)
            }
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 540, minHeight: 540)
    }

    @ViewBuilder private var page: some View {
        switch app.tab {
        case .general: GeneralTab(store: store, engine: engine)
        case .layout: LayoutTab(store: store)
        case .appearance: AppearanceTab(store: store)
        case .trackpad: MouseTab(store: store)
        case .displays: DisplaysTab(store: store)
        case .rules: RulesTab(store: store)
        case .shortcuts: ShortcutsTab(store: store, engine: engine, recorder: app.recorder, folds: app.placeFolds)
        case .macSetup: MacSetupTab(store: store)
        case .help: HelpTab(store: store)
        }
    }
}

struct ConfigErrorBanner: View {
    let message: String
    let isProblem: Bool
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if isProblem {
                Button("Open File") { app.openConfigFile() }
            } else {
                // config.json is good again; the note is about the copy of the user's file.
                Button("Show the Copy") { NSWorkspace.shared.activateFileViewerSelecting([app.store.brokenCopyURL]) }
                Button("OK") { app.store.dismissNote() }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }
}
