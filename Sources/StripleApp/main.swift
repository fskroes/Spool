import AppKit

// The uninstall script runs `Striple --unregister-login` before it removes the app, so no login item
// is left that points to a deleted app.
if CommandLine.arguments.contains("--unregister-login") {
    LoginItem.unregisterAll()
    exit(0)
}

if !SingleInstance.acquire() {
    SingleInstance.handOver(to: SingleInstance.other())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
