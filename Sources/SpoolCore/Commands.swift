import Foundation

/// Every action that a shortcut, the CLI, a URL or the menu can trigger.
public enum Command: Equatable, Hashable, Sendable {
    case focusLeft, focusRight, focusUp, focusDown
    case focusFirst, focusLast
    /// 1-based place in the strip. 9 means the last column.
    case focusIndex(Int)
    case moveLeft, moveRight, moveUp, moveDown
    case moveFirst, moveLast
    case moveToIndex(Int)
    case cycleWidth, toggleFullWidth, centerColumn, wider, narrower
    case taller, shorter, equalizeHeights
    case stackLeft, stackRight, popLeft, popRight
    case toggleTabbed, toggleFloat
    case sendToNextDisplay
    case focusWindow(WindowID)
    case start, stop, toggleEngine, restart
    /// Saves a mark: the state, stats, metrics and log of this moment (docs/METRICS.md).
    case mark

    /// The commands that can be bound to a key, in the order the Shortcuts page shows them.
    public static let bindable: [Command] = [
        .focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast,
        .focusIndex(1), .focusIndex(2), .focusIndex(3), .focusIndex(4), .focusIndex(5),
        .focusIndex(6), .focusIndex(7), .focusIndex(8), .focusIndex(9),
        .moveLeft, .moveRight, .moveUp, .moveDown, .moveFirst, .moveLast,
        .moveToIndex(1), .moveToIndex(2), .moveToIndex(3), .moveToIndex(4), .moveToIndex(5),
        .moveToIndex(6), .moveToIndex(7), .moveToIndex(8), .moveToIndex(9),
        .cycleWidth, .toggleFullWidth, .centerColumn, .wider, .narrower,
        .taller, .shorter, .equalizeHeights,
        .stackLeft, .stackRight, .popLeft, .popRight,
        .toggleTabbed, .toggleFloat, .sendToNextDisplay, .toggleEngine, .mark,
    ]

    /// The group on the Shortcuts page. Only bindable commands have one.
    public var group: ShortcutGroup? {
        switch self {
        case .focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast, .focusIndex: return .focus
        case .moveLeft, .moveRight, .moveUp, .moveDown, .moveFirst, .moveLast, .moveToIndex: return .move
        case .cycleWidth, .toggleFullWidth, .centerColumn, .wider, .narrower, .taller, .shorter, .equalizeHeights: return .size
        case .stackLeft, .stackRight, .popLeft, .popRight, .toggleTabbed: return .stacks
        case .toggleFloat, .sendToNextDisplay: return .windows
        case .toggleEngine, .mark: return .spool
        case .focusWindow, .start, .stop, .restart: return nil
        }
    }

    /// The place of `focusIndex` and `moveToIndex`. The Shortcuts page folds these nine-command runs into one row.
    public var placeIndex: Int? {
        switch self {
        case .focusIndex(let n), .moveToIndex(let n): return n
        default: return nil
        }
    }

    /// Stable name used in the config file, the CLI and URLs, for example `focus-left` or `focus-index-3`.
    public var name: String {
        switch self {
        case .focusLeft: return "focus-left"
        case .focusRight: return "focus-right"
        case .focusUp: return "focus-up"
        case .focusDown: return "focus-down"
        case .focusFirst: return "focus-first"
        case .focusLast: return "focus-last"
        case .focusIndex(let n): return "focus-index-\(n)"
        case .moveLeft: return "move-left"
        case .moveRight: return "move-right"
        case .moveUp: return "move-up"
        case .moveDown: return "move-down"
        case .moveFirst: return "move-first"
        case .moveLast: return "move-last"
        case .moveToIndex(let n): return "move-to-index-\(n)"
        case .cycleWidth: return "cycle-width"
        case .toggleFullWidth: return "toggle-full-width"
        case .centerColumn: return "center-column"
        case .wider: return "wider"
        case .narrower: return "narrower"
        case .taller: return "taller"
        case .shorter: return "shorter"
        case .equalizeHeights: return "equalize-heights"
        case .stackLeft: return "stack-left"
        case .stackRight: return "stack-right"
        case .popLeft: return "pop-left"
        case .popRight: return "pop-right"
        case .toggleTabbed: return "toggle-tabbed"
        case .toggleFloat: return "toggle-float"
        case .sendToNextDisplay: return "send-to-next-display"
        case .focusWindow(let id): return "focus-window-\(id)"
        case .start: return "start"
        case .stop: return "stop"
        case .toggleEngine: return "toggle-engine"
        case .restart: return "restart"
        case .mark: return "mark"
        }
    }

    /// Short label for menus and the Shortcuts page.
    public var title: String {
        switch self {
        case .focusLeft: return "Focus left"
        case .focusRight: return "Focus right"
        case .focusUp: return "Focus up in stack"
        case .focusDown: return "Focus down in stack"
        case .focusFirst: return "Focus first window"
        case .focusLast: return "Focus last window"
        case .focusIndex(let n): return n == 9 ? "Focus last place" : "Focus place \(n)"
        case .moveLeft: return "Move column left"
        case .moveRight: return "Move column right"
        case .moveUp: return "Move window up in stack"
        case .moveDown: return "Move window down in stack"
        case .moveFirst: return "Move column to first place"
        case .moveLast: return "Move column to last place"
        case .moveToIndex(let n): return n == 9 ? "Move column to last place" : "Move column to place \(n)"
        case .cycleWidth: return "Cycle preset widths"
        case .toggleFullWidth: return "Full width"
        case .centerColumn: return "Center column"
        case .wider: return "Wider"
        case .narrower: return "Narrower"
        case .taller: return "Taller (in a stack)"
        case .shorter: return "Shorter (in a stack)"
        case .equalizeHeights: return "Equalize heights"
        case .stackLeft: return "Stack into left column"
        case .stackRight: return "Stack into right column"
        case .popLeft: return "Pop out of stack to the left"
        case .popRight: return "Pop out of stack to the right"
        case .toggleTabbed: return "Tabbed column"
        case .toggleFloat: return "Float / unfloat"
        case .sendToNextDisplay: return "Send window to next display"
        case .focusWindow(let id): return "Focus window \(id)"
        case .start: return "Start"
        case .stop: return "Stop"
        case .toggleEngine: return "Start / stop the window manager"
        case .restart: return "Restart"
        case .mark: return "Mark this moment"
        }
    }

    private static let simple: [String: Command] = {
        let all: [Command] = [
            .focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast,
            .moveLeft, .moveRight, .moveUp, .moveDown, .moveFirst, .moveLast,
            .cycleWidth, .toggleFullWidth, .centerColumn, .wider, .narrower,
            .taller, .shorter, .equalizeHeights, .stackLeft, .stackRight, .popLeft, .popRight,
            .toggleTabbed, .toggleFloat, .sendToNextDisplay, .start, .stop, .toggleEngine, .restart, .mark,
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }()

    /// Every name `Command(name:)` accepts, for help output. Indexed commands are shown with `<n>`.
    public static var allNames: [String] {
        (simple.keys.sorted() + ["focus-index-<1-9>", "move-to-index-<1-9>", "focus-window-<id>"])
    }

    /// Parses a command name. Accepts `focus-index-3`, `focus-index 3` and `focus-index/3`.
    public init?(name raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        if let c = Command.simple[name] { self = c; return }
        func suffixNumber(_ prefix: String) -> Int? {
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count))
        }
        if let n = suffixNumber("focus-index-"), (1...9).contains(n) { self = .focusIndex(n); return }
        if let n = suffixNumber("move-to-index-"), (1...9).contains(n) { self = .moveToIndex(n); return }
        if let n = suffixNumber("focus-window-"), n >= 0, n <= Int(UInt32.max) { self = .focusWindow(WindowID(n)); return }
        return nil
    }
}

/// The sections of the Shortcuts page, in the order it shows them.
public enum ShortcutGroup: String, CaseIterable, Sendable {
    case focus, move, size, stacks, windows, spool

    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .move: return "Move"
        case .size: return "Width and height"
        case .stacks: return "Stacks and tabs"
        case .windows: return "Windows and displays"
        case .spool: return "Spool"
        }
    }

    /// Title of the folded row with the nine place commands, for example "Focus place 1 to 9".
    public var placesTitle: String? {
        switch self {
        case .focus: return "Focus place 1 to 9"
        case .move: return "Move column to place 1 to 9"
        default: return nil
        }
    }

    /// The bindable commands of this group in `Command.bindable` order: `single` without the place commands,
    /// `places` the place commands (empty when the group has none).
    public var commands: (single: [Command], places: [Command]) {
        let all = Command.bindable.filter { $0.group == self }
        return (all.filter { $0.placeIndex == nil }, all.filter { $0.placeIndex != nil })
    }
}

extension Command: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = Command(name: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown command \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
