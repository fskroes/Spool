import Foundation
import Testing

/// Runs scripts/install.sh with --dry-run in a temporary HOME. Nothing outside that folder changes.
@Suite struct InstallScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/install.sh")

    /// A fake Striple.app with the real bundle ID, and the CLI link `install` makes.
    static func fakeInstall(in home: URL, appsFolder: String) throws -> URL {
        let fm = FileManager.default
        let app = home.appendingPathComponent(appsFolder).appendingPathComponent("Striple.app")
        for dir in ["Contents/MacOS", "Contents/Helpers"] {
            try fm.createDirectory(at: app.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let plist: NSDictionary = ["CFBundleIdentifier": "com.fskroes.Striple"]
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        for exe in ["Contents/MacOS/Striple", "Contents/Helpers/striple"] {
            let url = app.appendingPathComponent(exe)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bin.appendingPathComponent("striple").path,
                                  withDestinationPath: app.appendingPathComponent("Contents/Helpers/striple").path)
        return app
    }

    static func run(_ args: [String], home: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func uninstallFindsAnAppInstalledWithPrefix() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("striple-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "Applications")

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        // The login agent is turned off and the app is removed, not only the CLI link.
        #expect(out.contains("[dry-run] \(app.path)/Contents/MacOS/Striple --unregister-login"))
        #expect(out.contains("[dry-run] rm -rf \(app.path)"))
        #expect(out.contains("[dry-run] rm -f \(home.path)/.local/bin/striple"))
    }

    @Test func uninstallKeepsAnAppThatIsNotStriple() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("striple-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let other = home.appendingPathComponent("Applications/Striple.app/Contents")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.example.other"] as NSDictionary).write(to: other.appendingPathComponent("Info.plist"))

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        #expect(out.contains("is not com.fskroes.Striple. Not removed."))
        #expect(!out.contains("rm -rf"))
    }
}
