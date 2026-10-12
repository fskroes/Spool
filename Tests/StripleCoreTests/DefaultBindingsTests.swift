import Testing
@testable import StripleCore

@Suite struct DefaultBindingsTests {
    /// Arrow shortcuts that macOS 26 has on by default, read with CGSGetSymbolicHotKeyValue (IDs 32-35, 79-82,
    /// 192-195, 205-206, 240-243, 248-255). Arrow keys always send the Fn flag, so Fn is left out here.
    static let macOSArrowShortcuts: Set<KeyCombo> = {
        let arrows = [KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down]
        let mods: [KeyModifiers] = [[], [.control], [.control, .shift], [.control, .option, .shift]]
        var out = Set(mods.flatMap { m in arrows.map { KeyCombo($0, m) } })
        out.insert(KeyCombo(KeyCode.left, [.option]))
        out.insert(KeyCombo(KeyCode.right, [.option]))
        return out
    }()

    @Test func defaultsAvoidTheMacOSArrowShortcuts() {
        let used = Set(DefaultBindings.make().values.joined())
        #expect(used.intersection(Self.macOSArrowShortcuts).isEmpty)
    }

    @Test func everyMoveHasADefault() {
        let b = DefaultBindings.make()
        for c in [Command.moveLeft, .moveRight, .moveUp, .moveDown] { #expect(!(b[c] ?? []).isEmpty) }
    }

    // Round 4 finding: configs saved before the ⌃⌥⇧ + arrow defaults were removed kept them, so the four move
    // shortcuts never worked, and commands added later had no shortcut at all.
    @Test func aVersion1ConfigLosesTheOldArrowMovesAndGetsNewCommands() throws {
        let cos: KeyModifiers = [.control, .option, .shift]
        let co: KeyModifiers = [.control, .option]
        var old = Config()
        old.version = 1
        old.bindings[.moveLeft] = [KeyCombo(KeyCode.h, cos), KeyCombo(KeyCode.left, cos)]
        old.bindings[.moveDown] = [KeyCombo(KeyCode.j, cos), KeyCombo(KeyCode.down, cos)]
        old.bindings[.cycleWidth] = []                         // cleared by the user
        old.bindings[.focusFirst] = [KeyCombo(KeyCode.q, co)]  // the user took toggle-engine's default
        old.bindings[.toggleEngine] = nil                      // not in the file: newer than the file
        old.bindings[.sendToNextDisplay] = nil

        let c = try Config.decode(old.encoded(), arrowsTaken: true)

        #expect(c.version == Config.currentVersion)
        #expect(c.bindings[.moveLeft] == [KeyCombo(KeyCode.h, cos)])
        #expect(c.bindings[.moveDown] == [KeyCombo(KeyCode.j, cos)])
        #expect(c.bindings[.cycleWidth] == [])
        #expect(c.bindings[.toggleEngine] == [])
        #expect(c.bindings[.sendToNextDisplay] == DefaultBindings.make()[.sendToNextDisplay])
        #expect(Set(c.bindings.values.joined()).intersection(Self.macOSArrowShortcuts).isEmpty)
    }

    @Test func aVersion2ConfigKeepsWhatTheUserChose() throws {
        var mine = Config()
        mine.bindings[.moveLeft] = [KeyCombo(KeyCode.left, [.control, .option, .shift])]
        let c = try Config.decode(mine.encoded())
        #expect(c.bindings[.moveLeft] == mine.bindings[.moveLeft])
        #expect(c == mine)
    }

    // Round 5 finding: on macOS 13 and 14 the migration removed combos that macOS does not use there.
    @Test func onMacOS13And14AVersion1ConfigKeepsTheArrowMoves() throws {
        let left = KeyCombo(KeyCode.left, [.control, .option, .shift])
        var old = Config()
        old.version = 1
        old.bindings[.moveLeft] = [left]
        let c = try Config.decode(old.encoded(), arrowsTaken: false)
        #expect(c.bindings[.moveLeft] == [left])
        // The version stays 1, so the migration runs after an upgrade to macOS 15.
        #expect(c.version == 1)
        let later = try Config.decode(c.encoded(), arrowsTaken: true)
        #expect(later.bindings[.moveLeft]?.contains(left) == false)
        #expect(later.version == Config.currentVersion)
    }
}
