import SwiftUI
import StripleCore
import StripleEngine

/// General settings. Every change applies at once.
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

            Section("Animation") {
                Toggle("Animate window moves", isOn: store.binding(\.animation.enabled))
                SliderRow(title: "Duration", value: store.binding(\.animation.response), range: 0.10...0.50, step: 0.01) {
                    String(format: "%.2f s", $0)
                }
                .disabled(!store.config.animation.enabled)
                Note("A shorter duration makes the windows move faster.")
            }

            Section("Strip") {
                Picker("Center the focused column", selection: store.binding(\.layout.centerMode)) {
                    ForEach(CenterMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                PercentRow(title: "Width of a new window", fraction: store.binding(\.layout.defaultWidth), range: 5...100)
                PercentRow(title: "Wider and narrower step", fraction: store.binding(\.layout.widthStep), range: 1...50, step: 1)
                PercentRow(title: "Taller and shorter step", fraction: store.binding(\.layout.heightStep), range: 1...50, step: 1)
                PresetWidthsEditor(store: store)
                NumberRow(title: "Tab bar height", value: store.binding(\.layout.tabBarHeight), range: 16...60)
            }

            Section("Gaps") {
                NumberRow(title: "Between windows", value: store.binding(\.layout.innerGap), range: 0...200)
                NumberRow(title: "Top edge", value: store.binding(\.layout.outerGaps.top), range: 0...400)
                NumberRow(title: "Bottom edge", value: store.binding(\.layout.outerGaps.bottom), range: 0...400)
                NumberRow(title: "Left edge", value: store.binding(\.layout.outerGaps.left), range: 0...400)
                NumberRow(title: "Right edge", value: store.binding(\.layout.outerGaps.right), range: 0...400)
            }

            Section("Trackpad") {
                Picker("Swipe to scroll the strip", selection: store.binding(\.gestures.fingers)) {
                    ForEach(SwipeFingers.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Natural direction (the strip moves with your fingers)", isOn: store.binding(\.gestures.natural))
                    .disabled(store.config.gestures.fingers == .off)
                SliderRow(title: "Sensitivity", value: store.binding(\.gestures.sensitivity), range: 0.25...3, step: 0.05) {
                    String(format: "%.2f×", $0)
                }
                .disabled(store.config.gestures.fingers == .off)
                if store.config.gestures.fingers != .off {
                    Note("macOS can use the same swipe to change Spaces. Mac Setup tells you what to change.")
                }
            }

            Section("Appearance") {
                Toggle("Border around the focused window", isOn: store.binding(\.appearance.focusBorder))
                Group {
                    NumberRow(title: "Border width", value: store.binding(\.appearance.borderWidth), range: 1...20)
                    ColorPicker("Border colour", selection: borderColor, supportsOpacity: true)
                }
                .disabled(!store.config.appearance.focusBorder)
                Toggle("Dim the other windows", isOn: store.binding(\.appearance.dimInactive))
                SliderRow(title: "Dim amount", value: store.binding(\.appearance.dimAmount), range: 0.05...0.8, step: 0.05) {
                    "\(Int(($0 * 100).rounded())) %"
                }
                .disabled(!store.config.appearance.dimInactive)
                Toggle("Show the strip map while you move", isOn: store.binding(\.appearance.minimap))
                SliderRow(title: "Map stays for", value: store.binding(\.appearance.minimapSeconds), range: 0.3...5, step: 0.1) {
                    String(format: "%.1f s", $0)
                }
                .disabled(!store.config.appearance.minimap)
            }

            Section("Behavior") {
                Toggle("Focus follows the mouse", isOn: store.binding(\.behavior.focusFollowsMouse))
                Toggle("Mouse follows the focus", isOn: store.binding(\.behavior.mouseFollowsFocus))
                Toggle("Drag a window to change its place on the strip", isOn: store.binding(\.behavior.dragToReorder))
                Toggle("Apps in the background cannot take the focus", isOn: store.binding(\.behavior.preventFocusStealing))
            }
        }
        .formStyle(.grouped)
    }

    private var borderColor: Binding<CGColor> {
        Binding(get: { ColorHex.cgColor(store.config.appearance.borderColor) },
                set: { color in
                    guard let hex = ColorHex.string(color) else { return }
                    store.update { $0.appearance.borderColor = hex }
                })
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
            Button(engine.status == .stopped ? "Start" : "Stop") { engine.toggle() }
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
                Note("macOS needs your approval. Allow Striple in Login Items.")
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
        store.update { $0.behavior.launchAtLogin = state == .enabled || state == .requiresApproval }
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
