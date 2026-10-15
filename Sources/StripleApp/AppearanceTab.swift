import SwiftUI
import StripleCore
import StripleEngine

/// What Striple draws: window moves, the focused window and the strip map.
struct AppearanceTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("Animation") {
                Toggle("Animate window moves", isOn: store.binding(\.animation.enabled))
                SliderRow(title: "Duration", value: store.binding(\.animation.response), range: 0.10...0.50, step: 0.01) {
                    String(format: "%.2f s", $0)
                }
                .disabled(!store.config.animation.enabled)
                Note("A shorter duration makes the windows move faster.")
            }

            Section("Focused window") {
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
            }

            Section("Strip map") {
                Toggle("Show the strip map while you move", isOn: store.binding(\.appearance.minimap))
                SliderRow(title: "Map stays for", value: store.binding(\.appearance.minimapSeconds), range: 0.3...5, step: 0.1) {
                    String(format: "%.1f s", $0)
                }
                .disabled(!store.config.appearance.minimap)
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
