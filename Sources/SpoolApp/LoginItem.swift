import Foundation
import ServiceManagement
import SpoolCore
import SpoolEngine

/// Launch at login. Prefers the bundled LaunchAgent, which has KeepAlive so launchd starts
/// Spool again after a crash. Falls back to the plain login item.
enum LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user must allow it in System Settings > General > Login Items.
        case requiresApproval
        /// Not in an app bundle (for example `swift run`).
        case unavailable
    }

    static let agentPlistName = "com.fskroes.Spool.agent.plist"
    /// The build stamp (see `currentBuild`) that registered the agent last.
    static let registeredBuildKey = "LoginItemRegisteredBuild"
    /// Set when the user turned launch at login off in a process that the agent started.
    static let offAtQuitKey = "LoginItemOffAtQuit"

    static var isAvailable: Bool { isAvailable(bundleID: Bundle.main.bundleIdentifier, isolated: SpoolPaths.isIsolated) }

    /// Only an app bundle has a login item. A test run (`SPOOL_HOME` set) never reads or changes it.
    static func isAvailable(bundleID: String?, isolated: Bool) -> Bool { bundleID != nil && !isolated }

    private static var agent: SMAppService { SMAppService.agent(plistName: agentPlistName) }
    private static var services: [SMAppService] { [agent, SMAppService.mainApp] }

    /// CFBundleVersion is the commit count, which stays the same for a rebuild without a new commit.
    /// The modification time of the executable changes with every build.
    private static var currentBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let path = Bundle.main.executableURL?.path ?? ""
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        return buildStamp(version: version, executableModified: modified)
    }

    static func buildStamp(version: String, executableModified: Date?) -> String {
        guard let executableModified else { return version }
        return "\(version)-\(Int(executableModified.timeIntervalSince1970))"
    }

    /// True when launch at login is off for the user but the agent is removed only when Spool quits.
    static var isOffAtQuit: Bool { UserDefaults.standard.bool(forKey: offAtQuitKey) }

    static var state: State {
        guard isAvailable else { return .unavailable }
        return state(statuses: services.map(\.status), offAtQuit: isOffAtQuit)
    }

    static func state(statuses: [SMAppService.Status], offAtQuit: Bool) -> State {
        if offAtQuit { return .disabled }
        if statuses.contains(.enabled) { return .enabled }
        if statuses.contains(.requiresApproval) { return .requiresApproval }
        return .disabled
    }

    static var isEnabled: Bool { state == .enabled }

    /// The toggle shows the real state: on only when Spool opens at the next login. A user who turns Spool
    /// off in System Settings > Login Items gets `.requiresApproval`, so that state shows off.
    static func showsOn(_ state: State) -> Bool { state == .enabled }

    /// SMAppService.h: unregistering a LaunchAgent that is running kills it. So a process that the agent
    /// started must not unregister the agent while it runs; it does so when it quits.
    static func mustWaitForQuit(startedByAgent: Bool, agentStatus: SMAppService.Status) -> Bool {
        startedByAgent && (agentStatus == .enabled || agentStatus == .requiresApproval)
    }

    /// The pending "off" is done when Spool quits, or at a launch that the agent did not start.
    static func shouldFinishOff(pending: Bool, atQuit: Bool, startedByAgent: Bool) -> Bool {
        pending && (atQuit || !startedByAgent)
    }

    /// Use the plain login item only when the agent is not registered at all. When the agent waits for approval,
    /// the user must approve it; registering the login item too would start Spool twice at every login.
    static func mayFallBack(agentStatus: SMAppService.Status) -> Bool {
        agentStatus == .notRegistered || agentStatus == .notFound
    }

    static func set(_ on: Bool) throws {
        guard isAvailable else { return }
        if on, isOffAtQuit {
            // The agent was never removed, so only the pending "off" goes away.
            UserDefaults.standard.removeObject(forKey: offAtQuitKey)
            if agent.status == .enabled { return }
        }
        if on {
            do {
                try agent.register()
                if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
                UserDefaults.standard.set(currentBuild, forKey: registeredBuildKey)
            } catch {
                guard mayFallBack(agentStatus: agent.status) else { throw error }
                NSLog("Spool: LaunchAgent registration failed (%@). Using the login item.", error.localizedDescription)
                try SMAppService.mainApp.register()
            }
        } else {
            let wait = mustWaitForQuit(startedByAgent: SingleInstance.startedByLaunchAgent, agentStatus: agent.status)
            let app = SMAppService.mainApp
            if app.status == .enabled || app.status == .requiresApproval { try app.unregister() }
            if wait {
                UserDefaults.standard.set(true, forKey: offAtQuitKey)
            } else {
                let agent = agent
                if agent.status == .enabled || agent.status == .requiresApproval { try agent.unregister() }
                UserDefaults.standard.removeObject(forKey: registeredBuildKey)
            }
        }
    }

    /// Removes the agent if the user turned launch at login off while the agent ran Spool.
    /// At quit this stops the process, which is quitting already.
    static func finishOffAtQuit(atQuit: Bool) {
        guard isAvailable,
              shouldFinishOff(pending: isOffAtQuit, atQuit: atQuit, startedByAgent: SingleInstance.startedByLaunchAgent)
        else { return }
        do {
            if agent.status == .enabled || agent.status == .requiresApproval { try agent.unregister() }
            UserDefaults.standard.removeObject(forKey: offAtQuitKey)
            UserDefaults.standard.removeObject(forKey: registeredBuildKey)
        } catch {
            NSLog("Spool: could not turn off the LaunchAgent: %@", error.localizedDescription)
        }
    }

    /// SMAppService.h: when the executable of a LaunchAgent changes, the agent "must be re-registered or it may
    /// not launch". Called at launch. Not done in a process that the agent started: unregistering the agent
    /// would stop that process.
    static func shouldRefresh(agentStatus: SMAppService.Status, registeredBuild: String?, currentBuild: String,
                              startedByAgent: Bool) -> Bool {
        agentStatus == .enabled && registeredBuild != currentBuild && !startedByAgent
    }

    static func refreshAfterUpdate() {
        guard isAvailable else { return }
        finishOffAtQuit(atQuit: false)
        if isOffAtQuit { return }
        let registered = UserDefaults.standard.string(forKey: registeredBuildKey)
        guard shouldRefresh(agentStatus: agent.status, registeredBuild: registered, currentBuild: currentBuild,
                            startedByAgent: SingleInstance.startedByLaunchAgent) else { return }
        do {
            try agent.unregister()
            try agent.register()
            UserDefaults.standard.set(currentBuild, forKey: registeredBuildKey)
            NSLog("Spool: registered the LaunchAgent again for build %@ (was %@).", currentBuild, registered ?? "none")
        } catch {
            NSLog("Spool: could not register the LaunchAgent again: %@", error.localizedDescription)
        }
    }

    /// Spool had the name Striple. The login item of Striple is gone (`install.sh` removes it), but the moved settings
    /// say "open at login". Then Spool registers its own login item once, so the setting stays as the user left it.
    static func shouldRestoreAfterRename(movedSettings: Bool, configOn: Bool, state: State) -> Bool {
        movedSettings && configOn && state == .disabled
    }

    static func restoreAfterRename(movedSettings: Bool, configOn: Bool) {
        guard isAvailable, shouldRestoreAfterRename(movedSettings: movedSettings, configOn: configOn, state: state) else { return }
        do {
            try set(true)
            EngineLog.shared.log("Striple is now Spool: Launch at login is on again, as it was for Striple.")
        } catch {
            EngineLog.shared.log("Striple is now Spool: could not turn Launch at login on: \(error.localizedDescription)")
        }
    }

    /// Called by `Spool --unregister-login` (the uninstall script) before the app is removed.
    static func unregisterAll() {
        guard !SpoolPaths.isIsolated else { return }
        for service in services where service.status != .notRegistered && service.status != .notFound {
            try? service.unregister()
        }
        UserDefaults.standard.removeObject(forKey: registeredBuildKey)
        UserDefaults.standard.removeObject(forKey: offAtQuitKey)
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
