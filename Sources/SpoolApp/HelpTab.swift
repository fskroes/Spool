import SwiftUI
import SpoolCore
import SpoolEngine

struct HelpTab: View {
    @ObservedObject var store: ConfigStore
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Spool") {
                LabeledRow("Version") { Text(app.appVersion).foregroundColor(.secondary).textSelection(.enabled) }
                Note("Windows sit side by side on a strip. A new window opens to the right of the focused one. The other windows keep their width.")
                Button("Show the Guide Again") { app.openGuide() }
            }

            Section("The five shortcuts to learn first") {
                EssentialShortcuts(store: store)
            }

            Section("Command line") {
                Note("The spool command runs every action from Terminal or a script.")
                CodeText("spool help")
                CodeText("spool focus-left")
                CodeText("spool state")
            }

            Section("URL scheme") {
                Note("Every action has a URL. Use it in Raycast, Alfred, Shortcuts or a browser.")
                CodeText("spool://focus-left")
                CodeText("spool://focus-index/3")
                CodeText("spool://settings")
            }

            Section("Files") {
                LabeledRow("Settings file") {
                    Text(store.fileURL.path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Open") { app.openConfigFile() }
                }
                LabeledRow("Engine log") {
                    Text(SpoolPaths.logFile.path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { app.revealLog() }
                }
                Note("You can edit the settings file in a text editor. Spool loads the changes at once.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The five shortcuts from the guide, with labels of the current keyboard layout.
struct EssentialShortcuts: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        ForEach(DefaultBindings.essentials, id: \.name) { command in
            LabeledRow(command.title) {
                let combos = store.config.bindings[command] ?? []
                if combos.isEmpty {
                    Text("No shortcut").foregroundColor(.secondary)
                } else {
                    ForEach(combos, id: \.self) { KeyChip(label: KeyLabel.label($0)) }
                }
            }
        }
    }
}

struct CodeText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
    }
}
