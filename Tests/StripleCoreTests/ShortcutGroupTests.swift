import Testing
@testable import StripleCore

/// The Shortcuts page shows `Command.bindable` in groups. A command missing from every group has no row,
/// so its shortcut cannot be changed.
@Suite struct ShortcutGroupTests {
    @Test func everyBindableCommandIsShownOnce() {
        let shown = ShortcutGroup.allCases.flatMap { $0.commands.single + $0.commands.places }
        #expect(shown.count == Command.bindable.count)
        #expect(Set(shown) == Set(Command.bindable))
    }

    @Test func groupsKeepTheBindableOrder() {
        for group in ShortcutGroup.allCases {
            let all = Command.bindable.filter { $0.group == group }
            let (single, places) = group.commands
            #expect(single == all.filter { $0.placeIndex == nil })
            #expect(places == all.filter { $0.placeIndex != nil })
        }
    }

    @Test func placeCommandsFoldIntoOneRowOfNine() {
        #expect(ShortcutGroup.focus.commands.places == (1...9).map(Command.focusIndex))
        #expect(ShortcutGroup.move.commands.places == (1...9).map(Command.moveToIndex))
        for group in ShortcutGroup.allCases where group != .focus && group != .move {
            #expect(group.commands.places.isEmpty)
            #expect(group.placesTitle == nil)
        }
        #expect(ShortcutGroup.focus.placesTitle != nil)
        #expect(ShortcutGroup.move.placesTitle != nil)
    }

    @Test func everyGroupHasACommand() {
        for group in ShortcutGroup.allCases { #expect(!group.commands.single.isEmpty) }
    }

    @Test func commandsThatCannotBeBoundHaveNoGroup() {
        for command: Command in [.start, .stop, .restart, .focusWindow(7)] {
            #expect(command.group == nil)
            #expect(!Command.bindable.contains(command))
        }
    }
}
