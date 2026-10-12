import AppKit
import SwiftUI
import StripleCore
import StripleEngine

/// Per-display on/off. Striple does not move windows on a display that is off.
struct DisplaysTab: View {
    @ObservedObject var store: ConfigStore
    @ViewState private var displays: [DisplayDescriptor] = []

    var body: some View {
        Form {
            Section {
                ForEach(displays) { display in
                    Toggle(isOn: enabled(display.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(display.name)
                                if display.isMain {
                                    Text("Main")
                                        .font(.caption)
                                        .padding(.horizontal, 5)
                                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                                }
                            }
                            Text(verbatim: "\(Int(display.frame.width)) × \(Int(display.frame.height)) points")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Tile windows on these displays")
            } footer: {
                Note("Each display has its own strip. When you turn a display off, Striple does not move its windows.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { displays = Displays.current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = Displays.current()
        }
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(get: { !store.config.disabledDisplays.contains(id) },
                set: { on in store.update { if on { $0.disabledDisplays.remove(id) } else { $0.disabledDisplays.insert(id) } } })
    }
}
