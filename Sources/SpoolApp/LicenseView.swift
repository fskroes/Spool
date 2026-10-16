import AppKit
import SwiftUI
import SpoolCore

/// The window that Spool shows while there is no valid license key.
struct LicenseView: View {
    @ObservedObject var gate: LicenseGate
    @EnvironmentObject var app: AppModel
    @ViewState private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activate Spool").font(.title2.bold())
            Text("Spool costs EUR 0.99, one time. Paste the license key from your email.")
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel("License key")
            if let error = gate.error {
                Text(error).font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Buy Spool (EUR 0.99)") { NSWorkspace.shared.open(LicenseKey.buyURL) }
                Button("Lost your key?") { NSWorkspace.shared.open(LicenseKey.restoreURL) }
                Spacer()
                // Return makes a new line in the paste field, so Activate has Command-Return.
                Button("Activate") { app.activateLicense(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Activate (Command-Return)")
                    .disabled(LicenseKey.normalized(text).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
