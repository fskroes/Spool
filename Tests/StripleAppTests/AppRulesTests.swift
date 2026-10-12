import Foundation
import ServiceManagement
import Testing
@testable import StripleApp
import StripleCore

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
    // Round 6 finding: turning Striple off in System Settings gives .requiresApproval, and the toggle stayed on.
    @Test func theToggleIsOnOnlyWhenStripleOpensAtLogin() {
        #expect(LoginItem.showsOn(.enabled))
        #expect(!LoginItem.showsOn(.requiresApproval))
        #expect(!LoginItem.showsOn(.disabled))
        #expect(!LoginItem.showsOn(.unavailable))
    }

    @Test func fallBackOnlyWhenTheAgentIsNotRegistered() {
        #expect(LoginItem.mayFallBack(agentStatus: .notRegistered))
        #expect(LoginItem.mayFallBack(agentStatus: .notFound))
        // Waiting for approval: a second login item would start Striple twice after approval.
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
}

@Suite struct SingleInstanceTests {
    @Test func onlyOneHolderOfTheLock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("striple-lock-\(UUID().uuidString)/instance.lock")
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
        #expect(URLRoute(URL(string: "striple://focus-right")!) == .command(.focusRight))
        #expect(URLRoute(URL(string: "striple://settings/shortcuts")!) == .settings(.shortcuts))
        #expect(URLRoute(URL(string: "striple://open")!) == .settings(nil))
        #expect(URLRoute(URL(string: "striple://rm-rf")!) == .unknown)
        #expect(URLRoute(URL(string: "https://focus-right")!) == .unknown)
    }
}
