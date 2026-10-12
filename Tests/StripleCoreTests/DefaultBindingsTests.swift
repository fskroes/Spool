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
}
