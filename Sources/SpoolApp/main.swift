import AppKit
import SpoolCore

// The uninstall script runs `Spool --unregister-login` before it removes the app, so no login item
// is left that points to a deleted app.
if CommandLine.arguments.contains("--unregister-login") {
    LoginItem.unregisterAll()
    exit(0)
}

// Spool had the name Striple before. Before the lock: the lock file would make the Spool folder, and then the
// settings of Striple would not move.
let migration = LegacyApp.takeOver()

if !SingleInstance.acquire() {
    SingleInstance.handOver(to: SingleInstance.other())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    delegate.migration = migration
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
