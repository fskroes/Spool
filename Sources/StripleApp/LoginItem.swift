import Foundation
import ServiceManagement

/// Launch at login. Prefers the bundled LaunchAgent, which has KeepAlive so launchd starts
/// Striple again after a crash. Falls back to the plain login item.
enum LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user must allow it in System Settings > General > Login Items.
        case requiresApproval
        /// Not in an app bundle (for example `swift run`).
        case unavailable
    }

    static let agentPlistName = "com.fskroes.Striple.agent.plist"
    /// The build stamp (see `currentBuild`) that registered the agent last.
    static let registeredBuildKey = "LoginItemRegisteredBuild"
    /// Set when the user turned launch at login off in a process that the agent started.
    static let offAtQuitKey = "LoginItemOffAtQuit"

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

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

    /// True when launch at login is off for the user but the agent is removed only when Striple quits.
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

    /// The toggle shows the real state: on only when Striple opens at the next login. A user who turns Striple
    /// off in System Settings > Login Items gets `.requiresApproval`, so that state shows off.
    static func showsOn(_ state: State) -> Bool { state == .enabled }

    /// SMAppService.h: unregistering a LaunchAgent that is running kills it. So a process that the agent
    /// started must not unregister the agent while it runs; it does so when it quits.
    static func mustWaitForQuit(startedByAgent: Bool, agentStatus: SMAppService.Status) -> Bool {
        startedByAgent && (agentStatus == .enabled || agentStatus == .requiresApproval)
    }

    /// The pending "off" is done when Striple quits, or at a launch that the agent did not start.
    static func shouldFinishOff(pending: Bool, atQuit: Bool, startedByAgent: Bool) -> Bool {
        pending && (atQuit || !startedByAgent)
    }

    /// Use the plain login item only when the agent is not registered at all. When the agent waits for approval,
    /// the user must approve it; registering the login item too would start Striple twice at every login.
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
                NSLog("Striple: LaunchAgent registration failed (%@). Using the login item.", error.localizedDescription)
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

    /// Removes the agent if the user turned launch at login off while the agent ran Striple.
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
            NSLog("Striple: could not turn off the LaunchAgent: %@", error.localizedDescription)
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
            NSLog("Striple: registered the LaunchAgent again for build %@ (was %@).", currentBuild, registered ?? "none")
        } catch {
            NSLog("Striple: could not register the LaunchAgent again: %@", error.localizedDescription)
        }
    }

    /// Called by `Striple --unregister-login` (the uninstall script) before the app is removed.
    static func unregisterAll() {
        for service in services where service.status != .notRegistered && service.status != .notFound {
            try? service.unregister()
        }
        UserDefaults.standard.removeObject(forKey: registeredBuildKey)
        UserDefaults.standard.removeObject(forKey: offAtQuitKey)
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
