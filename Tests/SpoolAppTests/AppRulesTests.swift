import Foundation
import ServiceManagement
import Testing
@testable import SpoolApp
import SpoolCore
import SpoolEngine

@Suite struct RecorderRulesTests {
    @Test func appShortcutsAreRefused() {
        // ⌘W closes windows in every app. As a global hotkey it would stop doing that.
        #expect(RecorderRules.evaluate(keyCode: KeyCode.w, modifiers: [.command]) == .appShortcut)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.tab, modifiers: [.command]) == .appShortcut)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.z, modifiers: [.command, .shift]) == .appShortcut)
    }

    @Test func combosWithControlOrOptionAreAccepted() {
        #expect(RecorderRules.evaluate(keyCode: KeyCode.h, modifiers: [.control, .option]) == .accept(KeyCombo(KeyCode.h, [.control, .option])))
        #expect(RecorderRules.evaluate(keyCode: KeyCode.h, modifiers: [.command, .option]) == .accept(KeyCombo(KeyCode.h, [.command, .option])))
    }

    @Test func functionKeysWorkAloneAndWithCommand() {
        let f5 = FunctionKeys.codes[4]
        #expect(RecorderRules.evaluate(keyCode: f5, modifiers: []) == .accept(KeyCombo(f5, [])))
        #expect(RecorderRules.evaluate(keyCode: f5, modifiers: [.command]) == .accept(KeyCombo(f5, [.command])))
    }

    @Test func systemShortcutsAreRefused() {
        let spaces = KeyCombo(KeyCode.right, [.control])
        #expect(RecorderRules.evaluate(keyCode: KeyCode.right, modifiers: [.control], systemShortcuts: [spaces]) == .systemShortcut(spaces))
        #expect(RecorderRules.evaluate(keyCode: KeyCode.right, modifiers: [.control]) == .accept(spaces))
    }

    @Test func typingKeysAndEscape() {
        #expect(RecorderRules.evaluate(keyCode: KeyCode.a, modifiers: []) == .needsModifier)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.a, modifiers: [.shift]) == .needsModifier)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.escape, modifiers: [.control]) == .cancel)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.delete, modifiers: []) == .cancel)
    }

    @Test func optionAloneTypesCharactersSoItIsRefused() {
        // ⌥2 is € (US), ⌥L is @ (German), ⌥⇧7 is \ (German), ⌥← moves the cursor one word.
        #expect(RecorderRules.evaluate(keyCode: KeyCode.two, modifiers: [.option]) == .typesCharacters)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.l, modifiers: [.option]) == .typesCharacters)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.seven, modifiers: [.option, .shift]) == .typesCharacters)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.left, modifiers: [.option]) == .typesCharacters)
        // With ⌃ or ⌘, or on a function key, ⌥ types nothing.
        #expect(RecorderRules.evaluate(keyCode: KeyCode.l, modifiers: [.option, .control]) == .accept(KeyCombo(KeyCode.l, [.option, .control])))
        let f5 = FunctionKeys.codes[4]
        #expect(RecorderRules.evaluate(keyCode: f5, modifiers: [.option]) == .accept(KeyCombo(f5, [.option])))
    }

    @Test func theRuleTextMatchesTheRules() {
        // The recorder hint and the Shortcuts tab show ruleText. It must name what evaluate accepts.
        #expect(RecorderRules.ruleText.contains("⌃"))
        #expect(RecorderRules.ruleText.contains("⌥ and ⌘ together"))
        #expect(!RecorderRules.ruleText.contains("⌘ alone"))
        #expect(RecorderRules.evaluate(keyCode: KeyCode.h, modifiers: [.control]) == .accept(KeyCombo(KeyCode.h, [.control])))
        #expect(RecorderRules.evaluate(keyCode: KeyCode.h, modifiers: [.option]) == .typesCharacters)
        #expect(RecorderRules.evaluate(keyCode: KeyCode.h, modifiers: [.command]) == .appShortcut)
    }
}

@Suite struct LoginItemRulesTests {
    // Round 6 finding: turning Spool off in System Settings gives .requiresApproval, and the toggle stayed on.
    @Test func theToggleIsOnOnlyWhenSpoolOpensAtLogin() {
        #expect(LoginItem.showsOn(.enabled))
        #expect(!LoginItem.showsOn(.requiresApproval))
        #expect(!LoginItem.showsOn(.disabled))
        #expect(!LoginItem.showsOn(.unavailable))
    }

    @Test func fallBackOnlyWhenTheAgentIsNotRegistered() {
        #expect(LoginItem.mayFallBack(agentStatus: .notRegistered))
        #expect(LoginItem.mayFallBack(agentStatus: .notFound))
        // Waiting for approval: a second login item would start Spool twice after approval.
        #expect(!LoginItem.mayFallBack(agentStatus: .requiresApproval))
        #expect(!LoginItem.mayFallBack(agentStatus: .enabled))
    }

    @Test func registerAgainOnlyAfterABuildChange() {
        #expect(LoginItem.shouldRefresh(agentStatus: .enabled, registeredBuild: "11", currentBuild: "12", startedByAgent: false))
        #expect(LoginItem.shouldRefresh(agentStatus: .enabled, registeredBuild: nil, currentBuild: "12", startedByAgent: false))
        #expect(!LoginItem.shouldRefresh(agentStatus: .enabled, registeredBuild: "12", currentBuild: "12", startedByAgent: false))
        // Unregistering the agent would stop the process that the agent started.
        #expect(!LoginItem.shouldRefresh(agentStatus: .enabled, registeredBuild: "11", currentBuild: "12", startedByAgent: true))
        #expect(!LoginItem.shouldRefresh(agentStatus: .notRegistered, registeredBuild: "11", currentBuild: "12", startedByAgent: false))
        #expect(!LoginItem.shouldRefresh(agentStatus: .requiresApproval, registeredBuild: "11", currentBuild: "12", startedByAgent: false))
    }

    @Test func rebuildWithoutANewCommitChangesTheStamp() {
        let first = LoginItem.buildStamp(version: "16", executableModified: Date(timeIntervalSince1970: 1_000))
        let rebuild = LoginItem.buildStamp(version: "16", executableModified: Date(timeIntervalSince1970: 1_060))
        #expect(first != rebuild)
        #expect(LoginItem.shouldRefresh(agentStatus: .enabled, registeredBuild: first, currentBuild: rebuild, startedByAgent: false))
        #expect(LoginItem.buildStamp(version: "16", executableModified: nil) == "16")
    }

    // SMAppService.h: unregistering a running LaunchAgent kills it.
    @Test func turningOffInAProcessTheAgentStartedWaitsForQuit() {
        #expect(LoginItem.mustWaitForQuit(startedByAgent: true, agentStatus: .enabled))
        #expect(!LoginItem.mustWaitForQuit(startedByAgent: false, agentStatus: .enabled))
        #expect(!LoginItem.mustWaitForQuit(startedByAgent: true, agentStatus: .notRegistered))

        #expect(LoginItem.shouldFinishOff(pending: true, atQuit: true, startedByAgent: true))
        #expect(LoginItem.shouldFinishOff(pending: true, atQuit: false, startedByAgent: false))
        #expect(!LoginItem.shouldFinishOff(pending: true, atQuit: false, startedByAgent: true))
        #expect(!LoginItem.shouldFinishOff(pending: false, atQuit: true, startedByAgent: false))

        #expect(LoginItem.state(statuses: [.enabled, .notRegistered], offAtQuit: true) == .disabled)
        #expect(LoginItem.state(statuses: [.enabled, .notRegistered], offAtQuit: false) == .enabled)
        #expect(LoginItem.state(statuses: [.notRegistered, .requiresApproval], offAtQuit: false) == .requiresApproval)
    }

    // Striple is now Spool. Its login item is gone, but its settings say "open at login": Spool turns it on once.
    @Test func launchAtLoginComesBackAfterTheRename() {
        #expect(LoginItem.shouldRestoreAfterRename(movedSettings: true, configOn: true, state: .disabled))
        // No move: the setting is Spool's own, and the user or System Settings decides it.
        #expect(!LoginItem.shouldRestoreAfterRename(movedSettings: false, configOn: true, state: .disabled))
        #expect(!LoginItem.shouldRestoreAfterRename(movedSettings: true, configOn: false, state: .disabled))
        #expect(!LoginItem.shouldRestoreAfterRename(movedSettings: true, configOn: true, state: .enabled))
        // Waiting for approval or not an app bundle: registering again does not help.
        #expect(!LoginItem.shouldRestoreAfterRename(movedSettings: true, configOn: true, state: .requiresApproval))
        #expect(!LoginItem.shouldRestoreAfterRename(movedSettings: true, configOn: true, state: .unavailable))
    }
}

@Suite struct SingleInstanceTests {
    @Test func onlyOneHolderOfTheLock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spool-lock-\(UUID().uuidString)/instance.lock")
        #expect(SingleInstance.acquire(at: url))
        // A second open file (another process, or here another descriptor) cannot take it.
        #expect(!SingleInstance.acquire(at: url))
        // A different process sees the same: flock(1) from the shell cannot get the lock either.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'a');\ntry:\n fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB); print('got')\nexcept OSError: print('busy')", url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "busy")
    }
}

@Suite struct URLRouteTests {
    @Test func routes() {
        #expect(URLRoute(URL(string: "spool://focus-right")!) == .command(.focusRight))
        #expect(URLRoute(URL(string: "spool://settings/shortcuts")!) == .settings(.shortcuts))
        #expect(URLRoute(URL(string: "spool://open")!) == .settings(nil))
        #expect(URLRoute(URL(string: "spool://rm-rf")!) == .unknown)
        #expect(URLRoute(URL(string: "https://focus-right")!) == .unknown)
    }

    @Test func licenseRoutes() {
        #expect(URLRoute(URL(string: "spool://license?key=SPOOL-abc.def")!) == .license("SPOOL-abc.def"))
        #expect(URLRoute(URL(string: "spool://license?key=SPOOL-abc%0A.def")!) == .license("SPOOL-abc.def"))
        // No key: the window opens.
        #expect(URLRoute(URL(string: "spool://license")!) == .license(""))
        #expect(URLRoute(URL(string: "https://license?key=SPOOL-abc.def")!) == .unknown)
        // `license` is not a command, so the route cannot start the engine without the license check.
        #expect(URLRoute(URL(string: "spool://command?name=license")!) == .unknown)
    }
}

@MainActor
@Suite struct LicenseGateTests {
    static let seed = Data(0..<32)
    static var publicKey: String { try! LicenseKey.publicKey(seed: seed).base64EncodedString() }
    static var key: String { try! LicenseKey.issue(id: "cs_test_1", email: "buyer@example.com", issued: "2026-01-02", seed: seed) }

    private func gate() -> LicenseGate {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-gate-test-\(UUID().uuidString)")
        return LicenseGate(keeper: LicenseKeeper(publicKey: Self.publicKey, inAppBundle: true,
                                                 file: LicenseFile(url: dir.appendingPathComponent("license.key"))))
    }

    @Test func aBadKeyShowsTheOneErrorText() {
        let g = gate()
        #expect(g.status == .unlicensed)
        #expect(!g.allowsStart)
        #expect(g.activate("SPOOL-nope") == .invalid)
        #expect(g.error == "This license key is not valid.")
        #expect(g.status == .unlicensed)
        #expect(g.licensedEmail == nil)
    }

    @Test func aGoodKeyLicensesTheGateAndClearsTheError() {
        let g = gate()
        _ = g.activate("SPOOL-nope")
        guard case .activated = g.activate(Self.key) else {
            Issue.record("a valid key must activate")
            return
        }
        #expect(g.error == nil)
        #expect(g.allowsStart)
        #expect(g.licensedEmail == "buyer@example.com")
    }

    // The test runner is not signed by the team of the releases, like a copy that was edited and signed again.
    @Test func aBundleNotSignedByTheTeamIsNotTrusted() {
        #expect(!LicenseGate.isSigned(Bundle.main, byTeam: LicenseKeeper.releaseTeam))
        #expect(!LicenseGate.isSigned(Bundle(path: "/System/Applications/Calculator.app")!, byTeam: LicenseKeeper.releaseTeam),
                "Apple's own signature is not the signature of the team")
    }

    // The engine asks before every start. A key file removed while Spool runs stops the next start.
    @Test func theCheckBeforeStartReadsTheKeyFileAgain() throws {
        let g = gate()
        #expect(!g.checkBeforeStart())
        guard case .activated = g.activate(Self.key) else {
            Issue.record("a valid key must activate")
            return
        }
        #expect(g.checkBeforeStart())
        try FileManager.default.removeItem(at: g.keeper.file.url)
        #expect(g.allowsStart, "the cached status has not seen the removal yet")
        #expect(!g.checkBeforeStart())
        #expect(g.status == .unlicensed)
    }

    @Test func aGateFromAPlainBuildAllowsStart() {
        let g = LicenseGate(keeper: LicenseKeeper(publicKey: nil, inAppBundle: false))
        #expect(g.status == .notRequired)
        #expect(g.allowsStart)
        #expect(g.licensedEmail == nil)
    }

    @Test func theStatusTextAndIcon() {
        #expect(Engine.Status.unlicensed.summary == "Spool needs a license key")
        #expect(StatusIcon.symbolName(.unlicensed) == "lock")
    }
}

/// A test run (`SPOOL_HOME` set) must never register or change the user's login item.
@Suite struct LoginItemIsolationTests {
    @Test func noLoginItemInATestRun() {
        #expect(LoginItem.isAvailable(bundleID: "com.fskroes.Spool", isolated: false))
        #expect(!LoginItem.isAvailable(bundleID: "com.fskroes.Spool", isolated: true))
        #expect(!LoginItem.isAvailable(bundleID: nil, isolated: false))
    }
}

/// Sparkle runs only with a feed URL, a public key and the SUEnableAutomaticChecks key.
@Suite struct UpdaterFeedTests {
    private let full: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key",
                                       "SUEnableAutomaticChecks": true]

    @Test func aFeedNeedsTheURLTheKeyAndTheAutomaticChecksSetting() {
        #expect(Updater.hasUpdateFeed(info: full))
        // The value of the setting does not matter: Sparkle asks for permission only when the key is missing.
        #expect(Updater.hasUpdateFeed(info: full.merging(["SUEnableAutomaticChecks": false]) { $1 }))
        for key in full.keys {
            #expect(!Updater.hasUpdateFeed(info: full.filter { $0.key != key }), "without \(key)")
        }
        #expect(!Updater.hasUpdateFeed(info: full.merging(["SUFeedURL": "  "]) { $1 }))
    }

    /// The app checks the key at launch; the build script must write it with the feed.
    @Test func theBuildScriptWritesTheAutomaticChecksSettingWithTheFeed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let feed = try #require(script.range(of: "plutil -replace SUFeedURL"))
        let tail = script[feed.upperBound...]
        let end = try #require(tail.range(of: "\nelse"))
        #expect(tail[..<end.lowerBound].contains("plutil -replace SUEnableAutomaticChecks -bool YES"))
    }
}

/// A test run must not check for updates: an update window would take the focus from the test windows.
@Suite struct UpdaterIsolationTests {
    @Test func noUpdaterInATestRun() {
        #expect(Updater.isEnabled(hasFeed: true, isolated: false))
        #expect(!Updater.isEnabled(hasFeed: true, isolated: true))
        #expect(!Updater.isEnabled(hasFeed: false, isolated: false))
    }
}
