import AppKit
import SpoolCore

/// Spool replaces Striple, its old name (`LegacyMigration.takeOver`). This file gives it the real system.
enum LegacyApp {
    /// Returns the lines for the engine log. When Striple does not stop, Spool tells the user and quits with
    /// status 0, so launchd does not start it again.
    static func takeOver() -> LegacyMigration.Result {
        let system = LegacyMigration.System(
            running: {
                NSRunningApplication.runningApplications(withBundleIdentifier: LegacyMigration.bundleID)
                    .filter { !$0.isTerminated }
                    .map { (pid: $0.processIdentifier, bundle: $0.bundleURL) }
            },
            installed: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: LegacyMigration.bundleID) },
            stop: { LegacyMigration.stop(pids: $0) },
            unregister: unregisterLogin,
            foldersLeft: { LegacyMigration.foldersLeft() },
            migrate: { LegacyMigration.migrate() })
        switch LegacyMigration.takeOver(isolated: SpoolPaths.isIsolated, system) {
        case .done(let result):
            result.lines.forEach { NSLog("Spool: %@", $0) }
            return result
        case .stripleStillRuns(let pids):
            NSLog("Spool: Striple (pid %@) did not quit. This Spool quits.", LegacyMigration.list(pids))
            MainActor.assumeIsolated { showStillRunning() }
            exit(0)
        }
    }

    /// Runs `Striple --unregister-login`: only Striple itself can turn off its login item. The flag ends Striple
    /// before it does anything else.
    private static func unregisterLogin(_ app: URL) -> String {
        let exe = Bundle(url: app)?.executableURL ?? app.appendingPathComponent("Contents/MacOS/Striple")
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--unregister-login"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "Striple is now Spool: could not turn off Launch at login of \(app.path): \(error.localizedDescription)"
        }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            return "Striple is now Spool: turning off Launch at login of \(app.path) took too long"
        }
        return process.terminationStatus == 0
            ? "Striple is now Spool: turned off Launch at login of \(app.path)"
            : "Striple is now Spool: could not turn off Launch at login of \(app.path) (status \(process.terminationStatus))"
    }

    /// Runs before main.swift creates the app object, so `NSApp` is still nil here.
    @MainActor private static func showStillRunning() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Striple is still running"
        alert.informativeText = "Spool is the new name of Striple. Quit Striple from its menu bar icon, then open Spool again."
        alert.runModal()
    }
}
