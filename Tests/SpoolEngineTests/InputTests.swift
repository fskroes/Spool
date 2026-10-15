import Carbon.HIToolbox
import Foundation
import CoreGraphics
import Testing
@testable import SpoolCore
@testable import SpoolEngine

@Suite struct SwipeTrackerTests {
    private func feed(_ t: inout SwipeTracker, _ samples: [(Int, Double, Double, Double)]) -> [SwipeTracker.Event] {
        samples.compactMap { t.feed(touches: $0.0, average: CGPoint(x: $0.1, y: $0.2), time: $0.3) }
    }

    @Test func horizontalSwipeBeginsChangesAndEnds() {
        var t = SwipeTracker(fingers: 4)
        let events = feed(&t, [(4, 0.5, 0.5, 0), (4, 0.51, 0.5, 0.01), (4, 0.53, 0.5, 0.02), (4, 0.6, 0.5, 0.03), (0, 0, 0, 0.04)])
        #expect(events.first == .began)
        #expect(events.contains(.changed(dx: 0.6 - 0.53)))
        guard case .ended(let v)? = events.last else { Issue.record("no end: \(events)"); return }
        #expect(v > 0)
        #expect(!t.isActive)
    }

    @Test func movementInsideTheDeadZoneIsNotASwipe() {
        var t = SwipeTracker(fingers: 3)
        let events = feed(&t, [(3, 0.5, 0.5, 0), (3, 0.505, 0.5, 0.01), (3, 0.51, 0.5, 0.02), (0, 0, 0, 0.03)])
        #expect(events.isEmpty)
    }

    @Test func verticalSwipeIsLeftToMacOS() {
        var t = SwipeTracker(fingers: 3)
        let events = feed(&t, [(3, 0.5, 0.5, 0), (3, 0.5, 0.56, 0.01), (3, 0.6, 0.56, 0.02), (3, 0.8, 0.56, 0.03)])
        #expect(events.isEmpty, "a gesture that starts vertical stays rejected: \(events)")
    }

    @Test func otherFingerCountsAreIgnored() {
        var t = SwipeTracker(fingers: 4)
        let events = feed(&t, [(3, 0.5, 0.5, 0), (3, 0.7, 0.5, 0.01), (2, 0.9, 0.5, 0.02)])
        #expect(events.isEmpty)
    }

    @Test func velocityUsesTheLastMoments() {
        var t = SwipeTracker(fingers: 4)
        // Fast at first, then the fingers stop for 200 ms before lifting: release velocity is about zero.
        var samples: [(Int, Double, Double, Double)] = [(4, 0.1, 0.5, 0), (4, 0.2, 0.5, 0.01), (4, 0.4, 0.5, 0.02)]
        for i in 1...20 { samples.append((4, 0.4, 0.5, 0.02 + Double(i) * 0.01)) }
        samples.append((0, 0, 0, 0.25))
        let events = feed(&t, samples)
        guard case .ended(let v)? = events.last else { Issue.record("no end"); return }
        #expect(abs(v) < 0.01)
    }
}

@Suite struct DisplayGeometryTests {
    @Test func singleDisplayFlipsTheMenuBarToTheTop() {
        let g = DisplayGeometryBuilder.make(screens: [(CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                        CGRect(x: 0, y: 70, width: 1440, height: 805))], primaryHeight: 900)
        #expect(g.count == 1)
        #expect(g[0].frame == CGRect(x: 0, y: 0, width: 1440, height: 900))
        // AppKit: Dock 70 pt at the bottom, menu bar 25 pt at the top. AX: y down.
        #expect(g[0].usable == CGRect(x: 0, y: 25, width: 1440, height: 805))
        #expect(!g[0].neighborLeft && !g[0].neighborRight && !g[0].neighborBelow)
    }

    @Test func sideBySideAndStackedNeighbours() {
        let screens: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 875)),
            (CGRect(x: 1440, y: -180, width: 1920, height: 1080), CGRect(x: 1440, y: -180, width: 1920, height: 1080)),
            (CGRect(x: 0, y: -900, width: 1440, height: 900), CGRect(x: 0, y: -900, width: 1440, height: 900)),
        ]
        let g = DisplayGeometryBuilder.make(screens: screens, primaryHeight: 900)
        #expect(g[0].neighborRight && !g[0].neighborLeft && g[0].neighborBelow)
        #expect(g[1].neighborLeft && !g[1].neighborRight)
        #expect(g[1].frame == CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        #expect(g[2].frame == CGRect(x: 0, y: 900, width: 1440, height: 900))
        #expect(!g[2].neighborBelow)
        // Display 1 spans y 0...1080 in AX and display 2 spans 900...1800: 180 pt of shared edge makes them neighbours.
        #expect(g[2].neighborRight)
        // Only a corner touch is not a neighbour.
        let corner = DisplayGeometryBuilder.make(screens: [screens[0], (CGRect(x: 1440, y: 900, width: 800, height: 600),
                                                                         CGRect(x: 1440, y: 900, width: 800, height: 600))],
                                                 primaryHeight: 900)
        #expect(!corner[0].neighborRight && !corner[1].neighborLeft)
    }
}

@MainActor @Suite struct HotkeyModifierTests {
    @Test func carbonModifiers() {
        #expect(Hotkeys.carbonModifiers([]) == 0)
        #expect(Hotkeys.carbonModifiers([.option]) == UInt32(optionKey))
        #expect(Hotkeys.carbonModifiers([.control, .option, .shift, .command])
            == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }
}

@MainActor @Suite struct HotkeyRegistrationTests {
    @Test func comboBoundTwiceIsNotARefusal() {
        // ⌃⌥⇧⌘F19 is free on any Mac; it is registered for a moment only.
        let combo = KeyCombo(80 /* F19 */, [.control, .option, .shift, .command])
        let hotkeys = Hotkeys { _ in }
        let refused = hotkeys.register([.focusLeft: [combo], .focusRight: [combo]])
        hotkeys.unregisterAll()
        #expect(refused.isEmpty)
    }

    @Test func systemShortcutListIsParsed() {
        let list: [[String: Any]] = [
            [kHISymbolicHotKeyCode as String: NSNumber(value: Int(KeyCode.space)), kHISymbolicHotKeyModifiers as String: NSNumber(value: cmdKey),
             kHISymbolicHotKeyEnabled as String: true],
            [kHISymbolicHotKeyCode as String: NSNumber(value: Int(KeyCode.right)), kHISymbolicHotKeyModifiers as String: NSNumber(value: controlKey),
             kHISymbolicHotKeyEnabled as String: false],
            [kHISymbolicHotKeyCode as String: NSNumber(value: 0xFFFF), kHISymbolicHotKeyModifiers as String: NSNumber(value: 0),
             kHISymbolicHotKeyEnabled as String: true],
        ]
        #expect(Hotkeys.systemShortcuts(from: list) == [KeyCombo(KeyCode.space, [.command])])
        #expect(Hotkeys.keyModifiers(carbon: UInt32(controlKey | shiftKey)) == [.control, .shift])
    }

    // Values as CopySymbolicHotKeys returns them on macOS 26: fn ⌃ F (tiling Fill), fn ⌃ ← (Spaces),
    // fn ⌃⌥⇧ ← (tiling Left & Quarters). Only the Fill shortcut needs the Fn key.
    @Test func fnFlagCountsOnlyOnKeysThatCarryItAnyway() {
        func entry(_ code: UInt16, _ mods: UInt32) -> [String: Any] {
            [kHISymbolicHotKeyCode as String: NSNumber(value: Int(code)), kHISymbolicHotKeyModifiers as String: NSNumber(value: mods),
             kHISymbolicHotKeyEnabled as String: true]
        }
        let list = [entry(KeyCode.f, 0x21000), entry(KeyCode.left, 0x21000), entry(KeyCode.right, 0x21a00), entry(80 /* F19 */, 0x20000)]
        #expect(Hotkeys.systemShortcuts(from: list) == [
            KeyCombo(KeyCode.left, [.control]),
            KeyCombo(KeyCode.right, [.control, .option, .shift]),
            KeyCombo(80, []),
        ])
    }
}
