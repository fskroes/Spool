import AppKit
import Testing
@testable import StripleEngine

@Suite struct ManageableAppTests {
    @Test func onlyRegularOtherRunningAppsAreManaged() {
        #expect(Policy.isManageableApp(policy: .regular, pid: 100, ownPID: 1, terminated: false))
        // The lock screen (loginwindow) and menu bar agents are not regular apps.
        #expect(!Policy.isManageableApp(policy: .accessory, pid: 100, ownPID: 1, terminated: false))
        #expect(!Policy.isManageableApp(policy: .prohibited, pid: 100, ownPID: 1, terminated: false))
        #expect(!Policy.isManageableApp(policy: .regular, pid: 1, ownPID: 1, terminated: false))
        #expect(!Policy.isManageableApp(policy: .regular, pid: 100, ownPID: 1, terminated: true))
    }

    @MainActor @Test func loginwindowIsNotManageable() throws {
        // loginwindow always runs; it is the frontmost app while the screen is locked.
        let lw = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first)
        #expect(!WindowTracker.isManageable(lw))
        #expect(!WindowTracker.manageableApps().contains { $0.bundleIdentifier == "com.apple.loginwindow" })
    }
}
