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
                Button("Buy Spool") { NSWorkspace.shared.open(LicenseGate.buyURL) }
                Button("Lost your key?") { NSWorkspace.shared.open(LicenseGate.restoreURL) }
                Spacer()
                Button("Activate") { app.activateLicense(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(LicenseKey.normalized(text).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
