import AppKit

if let other = SingleInstance.other() {
    SingleInstance.handOver(to: other)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
