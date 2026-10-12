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

    // Round 5 finding: a bad combo reset all shortcuts, and the next save wrote the loss to the user's file.
    @Test func aBadComboKeepsTheLastGoodConfigAndTheUsersFile() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        store.update { $0.bindings[.focusLeft] = [KeyCombo(KeyCode.h, [.command, .option])] }
        let mine = store.config.bindings
        let broken = #"{"version":2,"bindings":{"focus-left":[{"key":4,"mods":["ctrl","hyper"]}]}}"#
        try Data(broken.utf8).write(to: url)
        store.reload()
        #expect(store.config.bindings == mine)
        #expect(store.loadError?.contains("bindings.focus-left[0].mods") == true)
        #expect(store.loadError?.contains("hyper") == true)

        // A setting changes before the user fixes the file: the user's file is kept next to the saved one.
        store.update { $0.behavior.focusFollowsMouse = true }
        #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == broken)
        #expect(try Config.decode(Data(contentsOf: url)).bindings == mine)
        #expect(store.loadError?.contains("config.json.broken") == true)

        // A later save does not touch the copy again.
        store.update { $0.behavior.focusFollowsMouse = false }
        #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == broken)
    }

    // Round 5 finding: a version 1 file was migrated again on every load, so a combo added back by hand vanished.
    @Test func aMigratedFileIsSavedOnceAsTheCurrentVersion() throws {
        let url = tempFile()
        var old = Config()
        old.version = 1
        try old.encoded().write(to: url)
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(Config.fileVersion(try Data(contentsOf: url)) == Config.currentVersion)

        // The user adds ⌃⌥⇧← back by hand (after freeing it in System Settings). It stays.
        let left = KeyCombo(KeyCode.left, [.control, .option, .shift])
        var mine = store.config
        mine.bindings[.moveLeft] = [left]
        try mine.encoded().write(to: url)
        store.reload()
        #expect(store.config.bindings[.moveLeft] == [left])
    }

    // Round 6 finding: a broken file at launch gave factory settings, and the first automatic save wrote them.
    @Test func aBrokenFileAtLaunchStartsWithTheLastGoodSettings() throws {
        let url = tempFile()
        let first = ConfigStore(fileURL: url, watch: false)
        first.update { $0.layout.innerGap = 13; $0.behavior.onboardingDone = true }
        let broken = #"{"version":2,"bindings":{"focus-left":[{"key":4,"mods":["hyper"]}]}}"#
        try Data(broken.utf8).write(to: url)

        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.fileHasError)
        #expect(store.config.layout.innerGap == 13)
        #expect(store.config.behavior.onboardingDone)
        #expect(store.loadError?.contains("bindings.focus-left[0].mods") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)

        // A change by the user keeps the file as .broken, and the message still tells what was wrong.
        store.update { $0.behavior.focusFollowsMouse = true }
        #expect(!store.fileHasError)
        #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == broken)
        let saved = try Config.decode(Data(contentsOf: url))
        #expect(saved.layout.innerGap == 13 && saved.behavior.focusFollowsMouse)
        #expect(store.loadError?.contains("bindings.focus-left[0].mods") == true)
        #expect(store.loadError?.contains("config.json.broken") == true)
    }

    @Test func aBrokenFileWithNoLastGoodCopyStartsWithTheFactorySettings() throws {
        let url = tempFile()
        try Data("{ not json".utf8).write(to: url)
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.fileHasError)
        #expect(store.config == Config())
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    // Round 6 finding: after a broken file was deleted, every save failed on the copy step.
    @Test func aDeletedBrokenFileIsWrittenAgainOnTheNextSave() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        try Data("{ not json".utf8).write(to: url)
        store.reload()
        #expect(store.fileHasError)
        try FileManager.default.removeItem(at: url)
        store.reload()
        #expect(!store.fileHasError)
        #expect(store.loadError == nil)

        store.update { $0.layout.innerGap = 21 }
        #expect(store.loadError == nil)
        #expect(try Config.decode(Data(contentsOf: url)).layout.innerGap == 21)
        #expect(!FileManager.default.fileExists(atPath: store.brokenCopyURL.path))
    }

    @Test func anOldBrokenCopyIsReplacedByTheNewOne() throws {
        let url = tempFile()
        let store = ConfigStore(fileURL: url, watch: false)
        for text in ["{ first", "{ second"] {
            try Data(text.utf8).write(to: url)
            store.reload()
            store.update { $0.layout.innerGap += 1 }
            #expect(try String(contentsOf: store.brokenCopyURL, encoding: .utf8) == text)
        }
    }

    // Round 6 finding: on macOS 13 and 14 a version 1 file was saved as version 2, so the migration never ran later.
    @Test func aVersion1FileStaysVersion1UntilTheSystemTakesTheArrows() throws {
        let url = tempFile()
        let left = KeyCombo(KeyCode.left, [.control, .option, .shift])
        var old = Config()
        old.version = 1
        old.bindings[.moveLeft] = [left]
        let data = try old.encoded()
        try data.write(to: url)

        let onSonoma = ConfigStore(fileURL: url, watch: false, arrowsTaken: false)
        #expect(try Data(contentsOf: url) == data)
        onSonoma.update { $0.layout.innerGap = 17 }
        #expect(Config.fileVersion(try Data(contentsOf: url)) == 1)
        #expect(onSonoma.config.bindings[.moveLeft] == [left])

        let onSequoia = ConfigStore(fileURL: url, watch: false, arrowsTaken: true)
        #expect(onSequoia.config.bindings[.moveLeft]?.contains(left) == false)
        #expect(onSequoia.config.layout.innerGap == 17)
        #expect(Config.fileVersion(try Data(contentsOf: url)) == Config.currentVersion)
    }

    @Test func aFileWithoutAVersionIsNotRewritten() throws {
        let url = tempFile()
        let json = Data(#"{"layout":{"innerGap":9}}"#.utf8)
        try json.write(to: url)
        let store = ConfigStore(fileURL: url, watch: false)
        #expect(store.config.layout.innerGap == 9)
        #expect(try Data(contentsOf: url) == json)
    }
}
