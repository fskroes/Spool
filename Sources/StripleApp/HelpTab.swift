import SwiftUI
import StripleCore
import StripleEngine

struct HelpTab: View {
    @ObservedObject var store: ConfigStore
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Striple") {
                LabeledRow("Version") { Text(app.appVersion).foregroundColor(.secondary).textSelection(.enabled) }
                Note("Windows sit side by side on a strip. A new window opens to the right of the focused one. The other windows keep their width.")
                Button("Show the Guide Again") { app.openGuide() }
            }

            Section("The five shortcuts to learn first") {
                EssentialShortcuts(store: store)
            }

            Section("Command line") {
                Note("The striple command runs every action from Terminal or a script.")
                CodeText("striple help")
                CodeText("striple focus-left")
                CodeText("striple state")
            }

            Section("URL scheme") {
                Note("Every action has a URL. Use it in Raycast, Alfred, Shortcuts or a browser.")
                CodeText("striple://focus-left")
                CodeText("striple://focus-index/3")
                CodeText("striple://settings")
            }

            Section("Files") {
                LabeledRow("Settings file") {
                    Text(store.fileURL.path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Open") { app.openConfigFile() }
                }
                LabeledRow("Engine log") {
                    Text(StriplePaths.logFile.path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { app.revealLog() }
                }
                Note("You can edit the settings file in a text editor. Striple loads the changes at once.")
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
