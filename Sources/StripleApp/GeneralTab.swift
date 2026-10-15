import SwiftUI
import StripleCore
import StripleEngine

/// General settings: Striple itself, focus and metrics. Every change applies at once.
struct GeneralTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: Engine
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Striple") {
                EngineStatusRow(engine: engine)
                Toggle("Start tiling when Striple opens", isOn: store.binding(\.behavior.autoStart))
                LaunchAtLoginRow(store: store)
            }

            Section("Focus") {
                Toggle("Apps in the background cannot take the focus", isOn: store.binding(\.behavior.preventFocusStealing))
                Note("When an app opens a window on its own while you work in another app, Striple gives the focus back to you.")
            }

            Section("Metrics") {
                Toggle("Measure speed and usage on this Mac (local only)", isOn: store.binding(\.metrics.enabled))
                Note("Striple counts commands, frame times and problems in files on this Mac. No window titles and no keys. Nothing leaves the Mac. Run striple report to read them.")
                HStack {
                    Spacer()
                    Button("Open metrics folder", action: openMetricsFolder)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openMetricsFolder() {
        let folder = StriplePaths.metricsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

struct EngineStatusRow: View {
    @ObservedObject var engine: Engine
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(engine.status.summary)
            Spacer()
            if engine.status == .noPermission {
                Button("Mac Setup") { app.openSettings(.macSetup) }
            }
            Button(engine.status == .stopped ? "Start" : "Stop") { engine.perform(.toggleEngine, source: .menu) }
        }
    }

    private var color: Color {
        switch engine.status {
        case .running: return .green
        case .stopped: return .secondary
        case .noPermission: return .orange
        }
    }
}

struct LaunchAtLoginRow: View {
    @ObservedObject var store: ConfigStore
    @ViewState private var state = LoginItem.state
    @ViewState private var error: String?

    var body: some View {
        Toggle("Open Striple when you log in", isOn: Binding(get: { store.config.behavior.launchAtLogin }, set: set))
            .disabled(state == .unavailable)
            .onAppear { state = LoginItem.state }
            // The user approves Striple in System Settings and comes back: show the new state.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                state = LoginItem.state
                // The toggle too: the user can turn the login item off in System Settings.
                LoginItem.syncConfig(store)
            }
        if state == .unavailable {
            Note("Available in the app bundle.")
        }
        if state == .disabled, LoginItem.isOffAtQuit {
            Note("Striple stops opening at login when you quit it.")
        }
        if state == .requiresApproval {
            HStack {
                Note("Turned off in System Settings, or waiting for your approval. Allow Striple in Login Items.")
                Spacer()
                Button("Open Login Items") { LoginItem.openSystemSettings() }
            }
        }
        if let error {
            Note(error, color: .red)
        }
    }

    private func set(_ on: Bool) {
        do {
            try LoginItem.set(on)
            error = nil
        } catch {
            self.error = "Could not change the login item: \(error.localizedDescription)"
        }
        state = LoginItem.state
        store.update { $0.behavior.launchAtLogin = LoginItem.showsOn(state) }
    }
}

/// The preset widths that `cycle-width` steps through, as percentages.
struct PresetWidthsEditor: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        let widths = store.config.layout.presetWidths
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preset widths")
                Spacer()
                Button {
                    store.update { $0.layout.presetWidths.append(min((widths.last ?? 0.5) + 0.1, 1)) }
                } label: { Image(systemName: "plus") }
                .help("Add a preset width")
                .disabled(widths.count >= 8)
            }
            ForEach(widths.indices, id: \.self) { i in
                HStack {
                    PercentRow(title: "Preset \(i + 1)", fraction: width(at: i), range: 5...100)
                    Button {
                        store.update { if i < $0.layout.presetWidths.count { $0.layout.presetWidths.remove(at: i) } }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this preset width")
                    .disabled(widths.count <= 1)
                }
                .padding(.leading, 12)
            }
            Note("The cycle-width shortcut steps through these widths. Striple sorts them from small to large.")
        }
    }

    private func width(at i: Int) -> Binding<Double> {
        Binding(get: { i < store.config.layout.presetWidths.count ? store.config.layout.presetWidths[i] : 0.5 },
                set: { v in store.update { if i < $0.layout.presetWidths.count { $0.layout.presetWidths[i] = v } } })
    }
}
