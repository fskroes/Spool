import Foundation

/// Modifier keys of a shortcut.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// The usual macOS order: ⌃⌥⇧⌘.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }

    private static let names: [(String, KeyModifiers)] = [("ctrl", .control), ("opt", .option), ("shift", .shift), ("cmd", .command)]

    public init(from decoder: Decoder) throws {
        let list = try decoder.singleValueContainer().decode([String].self)
        var m = KeyModifiers()
        for item in list {
            switch item.lowercased() {
            case "ctrl", "control": m.insert(.control)
            case "opt", "option", "alt": m.insert(.option)
            case "shift": m.insert(.shift)
            case "cmd", "command": m.insert(.command)
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown modifier \(item)"))
            }
        }
        self = m
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(KeyModifiers.names.filter { contains($0.1) }.map(\.0))
    }
}

/// A key combination. The key is a hardware key code, so a binding stays on the
/// same physical key on every keyboard layout (AZERTY, QWERTZ, Dvorak).
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(_ keyCode: UInt16, _ modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey { case keyCode = "key", modifiers = "mods" }

    /// Label with US key names. The app replaces the key name with the label of the active layout.
    public var usLabel: String { modifiers.symbols + KeyCode.usName(keyCode) }
}

/// Hardware key codes (ANSI positions), from `HIToolbox/Events.h`.
public enum KeyCode {
    public static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3, h: UInt16 = 4
    public static let g: UInt16 = 5, z: UInt16 = 6, x: UInt16 = 7, c: UInt16 = 8, v: UInt16 = 9
    public static let b: UInt16 = 11, q: UInt16 = 12, w: UInt16 = 13, e: UInt16 = 14, r: UInt16 = 15
    public static let y: UInt16 = 16, t: UInt16 = 17
    public static let one: UInt16 = 18, two: UInt16 = 19, three: UInt16 = 20, four: UInt16 = 21
    public static let six: UInt16 = 22, five: UInt16 = 23, equal: UInt16 = 24, nine: UInt16 = 25
    public static let seven: UInt16 = 26, minus: UInt16 = 27, eight: UInt16 = 28, zero: UInt16 = 29
    public static let rightBracket: UInt16 = 30, o: UInt16 = 31, u: UInt16 = 32, leftBracket: UInt16 = 33
    public static let i: UInt16 = 34, p: UInt16 = 35, returnKey: UInt16 = 36, l: UInt16 = 37
    public static let j: UInt16 = 38, quote: UInt16 = 39, k: UInt16 = 40, semicolon: UInt16 = 41
    public static let backslash: UInt16 = 42, comma: UInt16 = 43, slash: UInt16 = 44, n: UInt16 = 45
    public static let m: UInt16 = 46, period: UInt16 = 47, tab: UInt16 = 48, space: UInt16 = 49
    public static let grave: UInt16 = 50, delete: UInt16 = 51, escape: UInt16 = 53
    public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    /// Digit keys 1 to 9 in order.
    public static let digits: [UInt16] = [one, two, three, four, five, six, seven, eight, nine]

    private static let usNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
        51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func usName(_ code: UInt16) -> String { usNames[code] ?? "Key\(code)" }

    /// Keys whose label does not depend on the keyboard layout.
    public static func isLayoutIndependent(_ code: UInt16) -> Bool {
        [returnKey, tab, space, delete, escape, left, right, down, up].contains(code) || (96...122).contains(code)
    }
}

/// The default shortcuts. All use Control-Option so plain Option stays free for typing.
public enum DefaultBindings {
    public static func make() -> [Command: [KeyCombo]] {
        let co: KeyModifiers = [.control, .option]
        let cos: KeyModifiers = [.control, .option, .shift]
        let coc: KeyModifiers = [.control, .option, .command]
        let cocs: KeyModifiers = [.control, .option, .command, .shift]
        var b: [Command: [KeyCombo]] = [
            .focusLeft: [KeyCombo(KeyCode.h, co), KeyCombo(KeyCode.left, co)],
            .focusDown: [KeyCombo(KeyCode.j, co), KeyCombo(KeyCode.down, co)],
            .focusUp: [KeyCombo(KeyCode.k, co), KeyCombo(KeyCode.up, co)],
            .focusRight: [KeyCombo(KeyCode.l, co), KeyCombo(KeyCode.right, co)],
            .focusFirst: [KeyCombo(KeyCode.left, coc)],
            .focusLast: [KeyCombo(KeyCode.right, coc)],
            .moveLeft: [KeyCombo(KeyCode.h, cos), KeyCombo(KeyCode.left, cos)],
            .moveDown: [KeyCombo(KeyCode.j, cos), KeyCombo(KeyCode.down, cos)],
            .moveUp: [KeyCombo(KeyCode.k, cos), KeyCombo(KeyCode.up, cos)],
            .moveRight: [KeyCombo(KeyCode.l, cos), KeyCombo(KeyCode.right, cos)],
            .moveFirst: [KeyCombo(KeyCode.left, cocs)],
            .moveLast: [KeyCombo(KeyCode.right, cocs)],
            .cycleWidth: [KeyCombo(KeyCode.r, co)],
            .toggleFullWidth: [KeyCombo(KeyCode.f, co)],
            .centerColumn: [KeyCombo(KeyCode.c, co)],
            .wider: [KeyCombo(KeyCode.equal, co)],
            .narrower: [KeyCombo(KeyCode.minus, co)],
            .taller: [KeyCombo(KeyCode.equal, cos)],
            .shorter: [KeyCombo(KeyCode.minus, cos)],
            .equalizeHeights: [KeyCombo(KeyCode.zero, co)],
            .stackLeft: [KeyCombo(KeyCode.leftBracket, co)],
            .stackRight: [KeyCombo(KeyCode.rightBracket, co)],
            .popLeft: [KeyCombo(KeyCode.leftBracket, cos)],
            .popRight: [KeyCombo(KeyCode.rightBracket, cos)],
            .toggleTabbed: [KeyCombo(KeyCode.t, cos)],
            .toggleFloat: [KeyCombo(KeyCode.t, co)],
            .sendToNextDisplay: [KeyCombo(KeyCode.n, co)],
            .toggleEngine: [KeyCombo(KeyCode.q, co)],
        ]
        for (i, key) in KeyCode.digits.enumerated() {
            b[.focusIndex(i + 1)] = [KeyCombo(key, co)]
            b[.moveToIndex(i + 1)] = [KeyCombo(key, cos)]
        }
        return b
    }

    /// The five shortcuts the guided start teaches.
    public static let essentials: [Command] = [.focusLeft, .focusRight, .moveLeft, .cycleWidth, .toggleFloat]
}

/// Finds combos that are bound to more than one command.
public func bindingConflicts(_ bindings: [Command: [KeyCombo]]) -> [KeyCombo: [Command]] {
    var seen: [KeyCombo: [Command]] = [:]
    for (command, combos) in bindings {
        for combo in Set(combos) { seen[combo, default: []].append(command) }
    }
    return seen.filter { $0.value.count > 1 }.mapValues { $0.sorted { $0.name < $1.name } }
}
