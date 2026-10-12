import Foundation
import Testing
@testable import StripleCore
@testable import StripleEngine

@MainActor
@Suite struct ConfigStoreTests {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    @Test func firstRunWritesDefaults() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.config == Config())
        #expect(try Config.decode(Data(contentsOf: url)) == Config())
    }

    @Test func updateSavesAndRoundTrips() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.layout.innerGap = 20; $0.appearance.focusBorder = true }
        let again = ConfigStore(fileURL: url, watch: false)
        #expect(again.config.layout.innerGap == 20)
        #expect(again.config.appearance.focusBorder)
    }

    @Test func externalEditIsLoaded() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        var c = store.config
        c.behavior.focusFollowsMouse = true
        try c.encoded().write(to: url)
        store.reload()
        #expect(store.config.behavior.focusFollowsMouse)
        #expect(store.loadError == nil)
    }

    @Test func brokenFileKeepsTheLastGoodConfig() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.layout.innerGap = 12 }
        try Data("{ not json".utf8).write(to: url)
        store.reload()
        #expect(store.config.layout.innerGap == 12)
        #expect(store.loadError != nil)
        // Fixing the file clears the error.
        var c = store.config
        c.layout.innerGap = 14
        try c.encoded().write(to: url)
        store.reload()
        #expect(store.loadError == nil)
        #expect(store.config.layout.innerGap == 14)
    }

    @Test func resetAllKeepsOnboardingDone() {
        let store = ConfigStore(fileURL: tempFile(), watch: false)
        store.update { $0.behavior.onboardingDone = true; $0.layout.innerGap = 30 }
        store.resetAll()
        #expect(store.config.behavior.onboardingDone)
        #expect(store.config.layout.innerGap == Config().layout.innerGap)
    }
}
