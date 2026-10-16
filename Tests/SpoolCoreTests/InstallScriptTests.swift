import Foundation
import Testing

/// Runs scripts/install.sh with --dry-run in a temporary HOME. Nothing outside that folder changes.
@Suite struct InstallScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/install.sh")

    /// A fake Spool.app with the real bundle ID, and the CLI link `install` makes. With `name: "Striple"`, the app
    /// of the old name.
    static func fakeInstall(in home: URL, appsFolder: String, name: String = "Spool",
                            bundleID: String? = nil) throws -> URL {
        let fm = FileManager.default
        let cli = name.lowercased()
        let app = home.appendingPathComponent(appsFolder).appendingPathComponent("\(name).app")
        for dir in ["Contents/MacOS", "Contents/Helpers"] {
            try fm.createDirectory(at: app.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let plist: NSDictionary = ["CFBundleIdentifier": bundleID ?? "com.fskroes.\(name)", "CFBundleExecutable": name]
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        for exe in ["Contents/MacOS/\(name)", "Contents/Helpers/\(cli)"] {
            let url = app.appendingPathComponent(exe)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bin.appendingPathComponent(cli).path,
                                  withDestinationPath: app.appendingPathComponent("Contents/Helpers/\(cli)").path)
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
        env["SPOOL_SYSTEM_APPS"] = home.appendingPathComponent("System Applications").path
        // No app runs: the result must not depend on the apps that run on this Mac.
        env["SPOOL_OSASCRIPT"] = "/usr/bin/false"
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
        for path in [app.appendingPathComponent("Contents/Helpers/spool").path, app.path] {
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
        FileManager.default.temporaryDirectory.appendingPathComponent("spool-install-\(UUID().uuidString)")
    }

    @Test func uninstallFindsAnAppInstalledWithPrefix() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "Applications")

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        // The login agent is turned off and the app is removed, not only the CLI link.
        #expect(out.contains("[dry-run] \(app.path)/Contents/MacOS/Spool --unregister-login"))
        #expect(out.contains("[dry-run] rm -rf \(app.path)"))
        #expect(out.contains("[dry-run] rm -f \(home.path)/.local/bin/spool"))
    }

    @Test func uninstallKeepsAnAppThatIsNotSpool() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let other = home.appendingPathComponent("Applications/Spool.app/Contents")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.example.other"] as NSDictionary).write(to: other.appendingPathComponent("Info.plist"))

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        #expect(out.contains("is not com.fskroes.Spool. Not removed."))
        #expect(!out.contains("rm -rf"))
    }

    // Round 4 finding: the tests never covered an app that only the CLI link can find.
    @Test func uninstallFindsAnAppThroughTheLink() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "My Apps")

        let out = try Self.run(["--uninstall", "--dry-run"], home: home)

        #expect(out.contains("[dry-run] rm -rf \(app.path.replacingOccurrences(of: " ", with: "\\ "))"))
        #expect(out.contains("[dry-run] rm -f \(home.path)/.local/bin/spool"))
    }

    // Round 4 finding: uninstalling another prefix removed the CLI link of the working install.
    @Test func uninstallWithAnotherPrefixKeepsTheLinkOfTheRealInstall() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.fakeInstall(in: home, appsFolder: "Applications")
        let other = home.appendingPathComponent("Other")

        let out = try Self.run(["--uninstall", "--dry-run", "--prefix", other.path], home: home)

        #expect(out.contains("No Spool.app found"))
        #expect(!out.contains("rm -rf"))
        #expect(!out.contains("rm -f"))
        #expect(out.contains("Keeping \(home.path)/.local/bin/spool: it points to \(app.path)"))
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

    // MARK: the team of the releases

    static let pinWarning = "is not signed by the team"

    /// A fake app, signed ad hoc, in a source folder outside the install prefix. `licenseKey` goes in
    /// SpoolLicensePublicKey of its Info.plist.
    static func adHocSource(in home: URL, licenseKey: String? = nil) throws -> URL {
        let app = try fakeInstall(in: home, appsFolder: "src")
        try FileManager.default.removeItem(at: home.appendingPathComponent(".local/bin/spool"))
        if let licenseKey {
            let url = app.appendingPathComponent("Contents/Info.plist")
            let plist = try #require(NSMutableDictionary(contentsOf: url))
            plist["SpoolLicensePublicKey"] = licenseKey
            try plist.write(to: url)
        }
        try sign(app)
        return app
    }

    // A build of `make e2e` has a public test key: anyone can make license keys for it.
    @Test func anAppWithATestLicenseKeyIsNotInstalled() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for key in [LicenseKeyTests.vectors.publicKeyA, LicenseKeyTests.vectors.publicKeyB] {
            let app = try Self.adHocSource(in: home, licenseKey: key)
            let r = try Self.runWithStatus(["--dry-run", "--app", app.path], home: home)
            #expect(r.status != 0)
            #expect(r.output.contains("has the public test license key of the E2E test"), "\(r.output)")
            #expect(!r.output.contains("Installing"))
            try FileManager.default.removeItem(at: home)
        }
        let real = try Self.adHocSource(in: home, licenseKey: Data(repeating: 7, count: 32).base64EncodedString())
        #expect(try Self.runWithStatus(["--dry-run", "--app", real.path], home: home).status == 0)
    }

    // An ad hoc app loses the Accessibility permission. The install says so, and goes on.
    @Test func anAppWithoutTheSignatureOfTheReleasesGivesAWarning() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.adHocSource(in: home)
        let env = try Self.temp(home, "updates.env", "SPOOL_TEAM_ID=98L4368F9K\n")

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path], home: home, env: ["SPOOL_UPDATES_ENV": env.path])

        #expect(r.status == 0, "\(r.output)")
        #expect(!r.output.contains(Self.pinWarning), "\(r.output)")
        #expect(r.output.contains("is signed ad hoc, not by the team 98L4368F9K of the releases"), "\(r.output)")
        #expect(r.output.contains("Reset Permission"), "\(r.output)")
        #expect(r.output.contains("run scripts/make-signing-cert.sh once"), "\(r.output)")
        #expect(r.output.contains("install the notarized release"), "\(r.output)")
        #expect(r.output.contains("Installing \(app.path)"))
        // The reported case: the switch is on, so Spool does not ask. Next steps must name the reset.
        #expect(r.output.contains("If the switch is on already, but Spool says \"Accessibility permission needed\""), "\(r.output)")
    }

    @Test(arguments: ["/dev/null", "empty pin"])
    func withoutAPinThereIsNoWarning(_ settings: String) throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.adHocSource(in: home)
        let path = settings == "/dev/null" ? settings : try Self.temp(home, "updates.env", "SPOOL_TEAM_ID=\n").path

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path], home: home, env: ["SPOOL_UPDATES_ENV": path])

        #expect(r.status == 0, "\(r.output)")
        #expect(!r.output.contains(Self.pinWarning), "\(r.output)")
        #expect(!r.output.contains("not by the team"), "\(r.output)")
    }

    // A wrong SPOOL_UPDATES_ENV must not turn off the check without a word.
    @Test func aMissingSettingsFileStopsTheInstall() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try Self.adHocSource(in: home)
        let missing = home.appendingPathComponent("no-such-updates.env").path

        let r = try Self.runWithStatus(["--dry-run", "--app", app.path], home: home, env: ["SPOOL_UPDATES_ENV": missing])

        #expect(r.status != 0)
        #expect(r.output.contains("\(missing) not found. Set SPOOL_UPDATES_ENV to the settings file."), "\(r.output)")
        #expect(!r.output.contains("Installing"))
    }

    // MARK: the upgrade from Striple, the old name

    @Test func installRemovesStripleItsLoginAgentAndItsLink() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)
        // Two copies: one in the system folder (the link points into it) and one in ~/Applications.
        let mine = try Self.fakeInstall(in: home, appsFolder: "Applications", name: "Striple")
        try FileManager.default.removeItem(at: home.appendingPathComponent(".local/bin/striple"))
        let striple = try Self.fakeInstall(in: home, appsFolder: "System Applications", name: "Striple")

        let r = try Self.runWithStatus(["--dry-run", "--app", source.path], home: home, env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status == 0, "\(r.output)")
        for app in [striple, mine] {
            let path = app.path.replacingOccurrences(of: " ", with: "\\ ")
            #expect(r.output.contains("[dry-run] \(path)/Contents/MacOS/Striple --unregister-login"), "\(r.output)")
            #expect(r.output.contains("[dry-run] rm -rf \(path)"), "\(r.output)")
        }
        #expect(r.output.contains("[dry-run] rm -f \(home.path)/.local/bin/striple"), "\(r.output)")
        #expect(r.output.contains("tccutil reset Accessibility com.fskroes.Striple"), "\(r.output)")
        // Striple goes after the copy: if the install stops before, Striple stays.
        let removed = try #require(r.output.range(of: "rm -rf \(home.path)/Applications/Striple.app"))
        let copied = try #require(r.output.range(of: "[dry-run] ditto"))
        #expect(copied.lowerBound < removed.lowerBound)
    }

    @Test func aRunningStripleQuitsBeforeTheCopy() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)
        _ = try Self.fakeInstall(in: home, appsFolder: "Applications", name: "Striple")
        // A fake osascript: only Striple runs.
        let osascript = home.appendingPathComponent("osascript")
        try Data("""
            #!/bin/sh
            case "$*" in *'"com.fskroes.Striple" is running'*) echo true ;; esac
            """.utf8).write(to: osascript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: osascript.path)

        let r = try Self.runWithStatus(["--dry-run", "--app", source.path], home: home,
                                       env: ["SPOOL_UPDATES_ENV": "/dev/null", "SPOOL_OSASCRIPT": osascript.path])

        #expect(r.status == 0, "\(r.output)")
        #expect(!r.output.contains("Quitting the running Spool"), "\(r.output)")
        let quit = try #require(r.output.range(of: "Quitting the running Striple"), "\(r.output)")
        #expect(r.output.contains(#"[dry-run] \#(osascript.path) -e quit\ app\ id\ \"com.fskroes.Striple\""#), "\(r.output)")
        let copied = try #require(r.output.range(of: "[dry-run] ditto"))
        #expect(quit.lowerBound < copied.lowerBound)
    }

    @Test func anAppAtTheDestinationThatIsNotSpoolStopsTheInstallBeforeStripleChanges() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)
        _ = try Self.fakeInstall(in: home, appsFolder: "Applications", name: "Striple")
        let prefix = home.appendingPathComponent("Apps")
        _ = try Self.fakeInstall(in: prefix, appsFolder: "", name: "Spool", bundleID: "com.example.other")

        let r = try Self.runWithStatus(["--dry-run", "--prefix", prefix.path, "--app", source.path], home: home,
                                       env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status != 0, "\(r.output)")
        #expect(r.output.contains("refusing to replace '\(prefix.path)/Spool.app': it is not com.fskroes.Spool"), "\(r.output)")
        #expect(!r.output.contains("Striple"), "\(r.output)")
        #expect(!r.output.contains("[dry-run]"), "\(r.output)")
    }

    @Test func installKeepsAStripleAppThatIsNotStriple() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)
        let other = try Self.fakeInstall(in: home, appsFolder: "Applications", name: "Striple", bundleID: "com.example.other")
        // A link to another app named striple stays too.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".local/bin/striple"))
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".local/bin/striple").path,
                                                   withDestinationPath: "/usr/local/bin/striple")

        let r = try Self.runWithStatus(["--dry-run", "--app", source.path], home: home, env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("\(other.path) is not com.fskroes.Striple. Not removed."), "\(r.output)")
        #expect(!r.output.contains("rm -rf"), "\(r.output)")
        #expect(!r.output.contains(".local/bin/striple"), "\(r.output)")
        #expect(!r.output.contains("tccutil"), "\(r.output)")
    }

    @Test func installWithPrefixRemovesTheStripleInThatFolder() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)
        let prefix = home.appendingPathComponent("Apps")
        let striple = try Self.fakeInstall(in: prefix, appsFolder: "", name: "Striple")

        let r = try Self.runWithStatus(["--dry-run", "--prefix", prefix.path, "--app", source.path], home: home,
                                       env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("[dry-run] rm -rf \(striple.path)"), "\(r.output)")
    }

    // Striple.app was deleted by hand: the link points to nothing, so it goes.
    @Test func installRemovesAStripleLinkIntoAMissingApp() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)
        let gone = try Self.fakeInstall(in: home, appsFolder: "Applications", name: "Striple")
        try FileManager.default.removeItem(at: gone)

        let r = try Self.runWithStatus(["--dry-run", "--app", source.path], home: home, env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("[dry-run] rm -f \(home.path)/.local/bin/striple"), "\(r.output)")
        #expect(!r.output.contains("rm -rf"), "\(r.output)")
    }

    // A real install (no dry run) into temporary folders. Spool is copied already when Striple cannot be removed:
    // the install warns and still makes the CLI link.
    @Test func aStripleThatCannotBeRemovedDoesNotStopTheInstall() throws {
        let fm = FileManager.default
        let home = Self.tempHome()
        let locked = home.appendingPathComponent("Applications")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: home)
        }
        let source = try Self.adHocSource(in: home)
        let striple = try Self.fakeInstall(in: home, appsFolder: "Applications", name: "Striple")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let prefix = home.appendingPathComponent("Apps")
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)

        let r = try Self.runWithStatus(["--prefix", prefix.path, "--app", source.path], home: home,
                                       env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("warning: could not remove \(striple.path). Delete it by hand."), "\(r.output)")
        #expect(fm.fileExists(atPath: striple.path))
        #expect(fm.fileExists(atPath: prefix.appendingPathComponent("Spool.app/Contents/Helpers/spool").path))
        let link = try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".local/bin/spool").path)
        #expect(link == prefix.appendingPathComponent("Spool.app/Contents/Helpers/spool").path)
        // The link of Striple stays with the app it points into.
        #expect((try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".local/bin/striple").path)) != nil)
    }

    @Test func installKeepsTheLinkIntoAStripleAppThatIsNotStriple() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)
        // The link points into this app, which has another bundle ID.
        let other = try Self.fakeInstall(in: home, appsFolder: "Applications", name: "Striple", bundleID: "com.example.other")

        let r = try Self.runWithStatus(["--dry-run", "--app", source.path], home: home, env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("\(other.path) is not com.fskroes.Striple. Not removed."), "\(r.output)")
        #expect(!r.output.contains("rm -f \(home.path)/.local/bin/striple"), "\(r.output)")
    }

    @Test func withoutStripleTheInstallSaysNothingAboutIt() throws {
        let home = Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try Self.adHocSource(in: home)

        let r = try Self.runWithStatus(["--dry-run", "--app", source.path], home: home, env: ["SPOOL_UPDATES_ENV": "/dev/null"])

        #expect(r.status == 0, "\(r.output)")
        #expect(!r.output.contains("--unregister-login"), "\(r.output)")
        #expect(!r.output.contains("rm -"), "\(r.output)")
        #expect(!r.output.contains("Striple"), "\(r.output)")
    }

    static func temp(_ home: URL, _ name: String, _ text: String) throws -> URL {
        let url = home.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
