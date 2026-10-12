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
    /// The build (CFBundleVersion) that registered the agent last.
    static let registeredBuildKey = "LoginItemRegisteredBuild"

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private static var agent: SMAppService { SMAppService.agent(plistName: agentPlistName) }
    private static var services: [SMAppService] { [agent, SMAppService.mainApp] }
    private static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    static var state: State {
        guard isAvailable else { return .unavailable }
        let statuses = services.map(\.status)
        if statuses.contains(.enabled) { return .enabled }
        if statuses.contains(.requiresApproval) { return .requiresApproval }
        return .disabled
    }

    static var isEnabled: Bool { state == .enabled }

    /// Use the plain login item only when the agent is not registered at all. When the agent waits for approval,
    /// the user must approve it; registering the login item too would start Striple twice at every login.
    static func mayFallBack(agentStatus: SMAppService.Status) -> Bool {
        agentStatus == .notRegistered || agentStatus == .notFound
    }

    static func set(_ on: Bool) throws {
        guard isAvailable else { return }
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
            for service in services where service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            UserDefaults.standard.removeObject(forKey: registeredBuildKey)
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
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
