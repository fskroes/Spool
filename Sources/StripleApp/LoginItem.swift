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

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private static var agent: SMAppService { SMAppService.agent(plistName: agentPlistName) }
    private static var services: [SMAppService] { [agent, SMAppService.mainApp] }

    static var state: State {
        guard isAvailable else { return .unavailable }
        let statuses = services.map(\.status)
        if statuses.contains(.enabled) { return .enabled }
        if statuses.contains(.requiresApproval) { return .requiresApproval }
        return .disabled
    }

    static var isEnabled: Bool { state == .enabled }

    static func set(_ on: Bool) throws {
        guard isAvailable else { return }
        if on {
            do {
                try agent.register()
                if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Striple: LaunchAgent registration failed (%@). Using the login item.", error.localizedDescription)
                try SMAppService.mainApp.register()
            }
        } else {
            for service in services where service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
