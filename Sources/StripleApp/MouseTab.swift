import SwiftUI
import StripleCore
import StripleEngine

/// The trackpad swipe and what the mouse does.
struct MouseTab: View {
    @ObservedObject var store: ConfigStore
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
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
                    HStack {
                        Note("macOS can use the same swipe to change Spaces. Mac Setup tells you what to change.")
                        Spacer()
                        Button("Mac Setup") { app.openSettings(.macSetup) }
                    }
                }
            }

            Section("Mouse") {
                Toggle("Focus follows the mouse", isOn: store.binding(\.behavior.focusFollowsMouse))
                Toggle("Mouse follows the focus", isOn: store.binding(\.behavior.mouseFollowsFocus))
                Toggle("Drag a window to change its place on the strip", isOn: store.binding(\.behavior.dragToReorder))
            }
        }
        .formStyle(.grouped)
    }
}
