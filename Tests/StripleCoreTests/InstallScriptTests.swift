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
        let plist: NSDictionary = ["CFBundleIdentifier": "com.fskroes.Striple", "CFBundleExecutable": "Striple"]
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

    /// Runs the script with HOME and the system Applications folder inside `home`, so the real
    /// /Applications of this Mac never counts. Returns the output and the exit status.
    @discardableResult
    static func run(_ args: [String], home: URL) throws -> String { try runWithStatus(args, home: home).output }

    static func runWithStatus(_ args: [String], home: URL, env extra: [String: String] = [:]) throws -> (output: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["STRIPLE_SYSTEM_APPS"] = home.appendingPathComponent("System Applications").path
        env.merge(extra) { _, new in new }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    /// Signs the fake app ad hoc (the helper first, then the bundle), so `codesign --verify` passes as for a real build.
    static func sign(_ app: URL) throws {
        for path in [app.appendingPathComponent("Contents/Helpers/striple").path, app.path] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["-s", "-", "--force", path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
    }

    static func tempHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("striple-install-\(UUID().uuidString)")
    }

    @Test func uninstallFindsAnAppInstalledWithPrefix() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "Applications")

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        // The login agent is turned off and the app is removed, not only the CLI link.
        #expect(out.contains("[dry-run] \(app.path)/Contents/MacOS/Striple --unregister-login"))
        #expect(out.contains("[dry-run] rm -rf \(app.path)"))
        #expect(out.contains("[dry-run] rm -f \(home.path)/.local/bin/striple"))
    }

    @Test func uninstallKeepsAnAppThatIsNotStriple() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let other = home.appendingPathComponent("Applications/Striple.app/Contents")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.example.other"] as NSDictionary).write(to: other.appendingPathComponent("Info.plist"))

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        #expect(out.contains("is not com.fskroes.Striple. Not removed."))
        #expect(!out.contains("rm -rf"))
    }

    // Round 4 finding: the tests never covered an app that only the CLI link can find.
    @Test func uninstallFindsAnAppThroughTheLink() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "My Apps")

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        #expect(out.contains("[dry-run] rm -rf \(app.path.replacingOccurrences(of: " ", with: "\\ "))"))
        #expect(out.contains("[dry-run] rm -f \(home.path)/.local/bin/striple"))
    }

    // Round 4 finding: uninstalling another prefix removed the CLI link of the working install.
    @Test func uninstallWithAnotherPrefixKeepsTheLinkOfTheRealInstall() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "Applications")
        let other = home.appendingPathComponent("Other")

        let out = try Self.run(["--uninstall", "--dry-run", "--prefix", other.path], home: home)

        #expect(out.contains("No Striple.app found"))
        #expect(!out.contains("rm -rf"))
        #expect(!out.contains("rm -f"))
        #expect(out.contains("Keeping \(home.path)/.local/bin/striple: it points to \(app.path)"))
    }

    // Round 4 finding: installing an app onto itself deleted it before the copy.
    @Test func installOntoItselfStops() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "Applications")
        try Self.sign(app)

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path, "--prefix", app.deletingLastPathComponent().path], home: home)

        #expect(r.status != 0)
        #expect(r.output.contains("is already at"))
        #expect(!r.output.contains("rm -rf"))
        #expect(!r.output.contains("ditto"))
    }

    // Round 5 finding: the same app typed with other letter case passed the check and was deleted.
    @Test func installOntoItselfInOtherLetterCaseStops() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "Applications")
        try Self.sign(app)
        let lower = home.appendingPathComponent("applications")
        // Only on a case-insensitive volume (the default on macOS) is this the same folder.
        guard FileManager.default.fileExists(atPath: lower.path) else { return }

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path, "--prefix", lower.path], home: home)

        #expect(r.status != 0)
        #expect(r.output.contains("is already at"))
        #expect(!r.output.contains("rm -rf"))
    }

    // MARK: the pinned identity

    static let pinWarning = "is not signed with the pinned identity"

    /// A fake app, signed ad hoc, in a source folder outside the install prefix.
    static func adHocSource(in home: URL) throws -> URL {
        let app = try fakeInstall(in: home, appsFolder: "src")
        try FileManager.default.removeItem(at: home.appendingPathComponent(".local/bin/striple"))
        try sign(app)
        return app
    }

    // An ad hoc app loses the Accessibility permission. The install says so, and goes on.
    @Test func anAppWithoutThePinnedIdentityGivesAWarning() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.adHocSource(in: home)
        let env = try Self.temp(home, "updates.env", "STRIPLE_SIGNING_CERT_SHA1=B608FA4F3D9A1FC14CDBAB47421A660E429053DC\n")

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path], home: home, env: ["STRIPLE_UPDATES_ENV": env.path])

        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("\(app.path) \(Self.pinWarning) B608FA4F3D9A1FC14CDBAB47421A660E429053DC"), "\(r.output)")
        #expect(r.output.contains("macOS asks for the Accessibility permission again"))
        #expect(r.output.contains("Installing \(app.path)"))
    }

    @Test(arguments: ["/dev/null", "empty pin"])
    func withoutAPinThereIsNoWarning(_ settings: String) throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.adHocSource(in: home)
        let path = settings == "/dev/null" ? settings : try Self.temp(home, "updates.env", "STRIPLE_SIGNING_CERT_SHA1=\n").path

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path], home: home, env: ["STRIPLE_UPDATES_ENV": path])

        #expect(r.status == 0, "\(r.output)")
        #expect(!r.output.contains(Self.pinWarning), "\(r.output)")
    }

    // A wrong STRIPLE_UPDATES_ENV must not turn off the check without a word.
    @Test func aMissingSettingsFileStopsTheInstall() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.adHocSource(in: home)
        let missing = home.appendingPathComponent("no-such-updates.env").path

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path], home: home, env: ["STRIPLE_UPDATES_ENV": missing])

        #expect(r.status != 0)
        #expect(r.output.contains("\(missing) not found. Set STRIPLE_UPDATES_ENV to the settings file."), "\(r.output)")
        #expect(!r.output.contains("Installing"))
    }

    static func temp(_ home: URL, _ name: String, _ text: String) throws -> URL {
        let url = home.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
