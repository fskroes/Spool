import Foundation

extension KeyedDecodingContainer {
    /// Decodes a value or returns the default, so an older or partial config file still loads.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }

    /// For lists the user edits by hand (shortcuts, rules, displays). A bad entry is an error, so the store keeps
    /// the last good settings and shows why. A default would silently replace every entry of the list.
    func strict<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

extension CodingUserInfoKey {
    /// Bool: macOS uses ⌃⌥⇧ + arrow for window tiling. Set by `Config.decode`; tests set it to check both cases.
    static let arrowsTakenBySystem = CodingUserInfoKey(rawValue: "striple.arrowsTakenBySystem")!
}

public enum CenterMode: String, Codable, CaseIterable, Sendable {
    case never, onOverflow, always

    public var title: String {
        switch self {
        case .never: return "Never"
        case .onOverflow: return "When the strip overflows"
        case .always: return "Always"
        }
    }
}

public struct EdgeGaps: Codable, Equatable, Sendable {
    public var top: Double, bottom: Double, left: Double, right: Double

    public init(top: Double = 8, bottom: Double = 8, left: Double = 8, right: Double = 8) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EdgeGaps()
        top = c.value(.top, d.top); bottom = c.value(.bottom, d.bottom)
        left = c.value(.left, d.left); right = c.value(.right, d.right)
    }
}

public struct LayoutSettings: Codable, Equatable, Sendable {
    public var innerGap: Double = 8
    public var outerGaps = EdgeGaps()
    public var centerMode: CenterMode = .onOverflow
    /// Preset widths as parts of the usable width, cycled by `cycle-width`.
    public var presetWidths: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    public var defaultWidth: Double = 0.5
    public var widthStep: Double = 0.1
    public var heightStep: Double = 0.1
    public var tabBarHeight: Double = 24
    /// Points that stay visible of a parked (hidden) window. macOS does not let a window go fully off screen.
    public var parkedSliver: Double = 1

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LayoutSettings()
        innerGap = c.value(.innerGap, d.innerGap)
        outerGaps = c.value(.outerGaps, d.outerGaps)
        centerMode = c.value(.centerMode, d.centerMode)
        presetWidths = c.value(.presetWidths, d.presetWidths)
        defaultWidth = c.value(.defaultWidth, d.defaultWidth)
        widthStep = c.value(.widthStep, d.widthStep)
        heightStep = c.value(.heightStep, d.heightStep)
        tabBarHeight = c.value(.tabBarHeight, d.tabBarHeight)
        parkedSliver = c.value(.parkedSliver, d.parkedSliver)
    }

    /// Clamps values that would break the layout.
    public func sanitized() -> LayoutSettings {
        var s = self
        s.innerGap = min(max(s.innerGap, 0), 200)
        s.outerGaps = EdgeGaps(top: min(max(s.outerGaps.top, 0), 400), bottom: min(max(s.outerGaps.bottom, 0), 400),
                               left: min(max(s.outerGaps.left, 0), 400), right: min(max(s.outerGaps.right, 0), 400))
        s.presetWidths = s.presetWidths.map { min(max($0, 0.05), 1) }.sorted()
        if s.presetWidths.isEmpty { s.presetWidths = LayoutSettings().presetWidths }
        s.defaultWidth = min(max(s.defaultWidth, 0.05), 1)
        s.widthStep = min(max(s.widthStep, 0.01), 0.5)
        s.heightStep = min(max(s.heightStep, 0.01), 0.5)
        s.tabBarHeight = min(max(s.tabBarHeight, 16), 60)
        s.parkedSliver = min(max(s.parkedSliver, 1), 20)
        return s
    }
}

public struct AnimationSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// Time in seconds the spring needs to get most of the way. Smaller is faster.
    public var response: Double = 0.22

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnimationSettings()
        enabled = c.value(.enabled, d.enabled)
        response = c.value(.response, d.response)
    }
}

public enum SwipeFingers: Int, Codable, CaseIterable, Sendable {
    case off = 0, three = 3, four = 4

    public var title: String {
        switch self {
        case .off: return "Off"
        case .three: return "3 fingers"
        case .four: return "4 fingers"
        }
    }
}

public struct GestureSettings: Codable, Equatable, Sendable {
    public var fingers: SwipeFingers = .four
    /// Natural: the strip moves with the fingers, like scrolling a page.
    public var natural = true
    public var sensitivity: Double = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureSettings()
        fingers = c.value(.fingers, d.fingers)
        natural = c.value(.natural, d.natural)
        sensitivity = c.value(.sensitivity, d.sensitivity)
    }
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var focusBorder = false
    public var borderWidth: Double = 4
    /// Colour as `#RRGGBB` or `#RRGGBBAA`.
    public var borderColor = "#4C8DFF"
    public var dimInactive = false
    public var dimAmount: Double = 0.25
    public var minimap = true
    public var minimapSeconds: Double = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        focusBorder = c.value(.focusBorder, d.focusBorder)
        borderWidth = c.value(.borderWidth, d.borderWidth)
        borderColor = c.value(.borderColor, d.borderColor)
        dimInactive = c.value(.dimInactive, d.dimInactive)
        dimAmount = c.value(.dimAmount, d.dimAmount)
        minimap = c.value(.minimap, d.minimap)
        minimapSeconds = c.value(.minimapSeconds, d.minimapSeconds)
    }
}

public struct BehaviorSettings: Codable, Equatable, Sendable {
    public var focusFollowsMouse = false
    public var mouseFollowsFocus = false
    public var dragToReorder = true
    public var preventFocusStealing = true
    public var autoStart = true
    public var launchAtLogin = false
    public var onboardingDone = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BehaviorSettings()
        focusFollowsMouse = c.value(.focusFollowsMouse, d.focusFollowsMouse)
        mouseFollowsFocus = c.value(.mouseFollowsFocus, d.mouseFollowsFocus)
        dragToReorder = c.value(.dragToReorder, d.dragToReorder)
        preventFocusStealing = c.value(.preventFocusStealing, d.preventFocusStealing)
        autoStart = c.value(.autoStart, d.autoStart)
        launchAtLogin = c.value(.launchAtLogin, d.launchAtLogin)
        onboardingDone = c.value(.onboardingDone, d.onboardingDone)
    }
}

/// Local metrics (docs/METRICS.md). Off: Striple records nothing and writes no metrics file.
public struct MetricsSettings: Codable, Equatable, Sendable {
    public var enabled = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MetricsSettings()
        enabled = c.value(.enabled, d.enabled)
    }
}

public struct AppRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Action: Codable, Equatable, Hashable, Sendable {
        case float
        case tile
        /// 1-based place on the strip.
        case slot(Int)
    }

    public var bundleID: String
    public var appName: String
    public var action: Action
    public var id: String { bundleID }

    public init(bundleID: String, appName: String, action: Action) {
        self.bundleID = bundleID
        self.appName = appName
        self.action = action
    }
}

/// Every setting. Stored as JSON in `~/Library/Application Support/Striple/config.json`.
public struct Config: Codable, Equatable, Sendable {
    /// 2: the ⌃⌥⇧ + arrow move shortcuts were removed (macOS 15 and later use them for window tiling).
    public static let currentVersion = 2

    /// macOS 15 and later use ⌃⌥⇧ + arrow (with Fn) for window tiling.
    public static var systemTakesArrows: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    public var version = Config.currentVersion
    public var layout = LayoutSettings()
    public var animation = AnimationSettings()
    public var gestures = GestureSettings()
    public var appearance = AppearanceSettings()
    public var behavior = BehaviorSettings()
    public var metrics = MetricsSettings()
    /// Display UUIDs on which Striple does not manage windows.
    public var disabledDisplays: Set<String> = []
    public var rules: [AppRule] = []
    public var bindings: [Command: [KeyCombo]] = DefaultBindings.make()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, layout, animation, gestures, appearance, behavior, metrics, disabledDisplays, rules, bindings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        version = c.value(.version, d.version)
        layout = c.value(.layout, d.layout)
        animation = c.value(.animation, d.animation)
        gestures = c.value(.gestures, d.gestures)
        appearance = c.value(.appearance, d.appearance)
        behavior = c.value(.behavior, d.behavior)
        metrics = c.value(.metrics, d.metrics)
        disabledDisplays = try c.strict(.disabledDisplays, d.disabledDisplays)
        rules = try c.strict(.rules, d.rules)
        // An unknown command name is skipped (it can come from a newer Striple). A bad combo is an error.
        if let raw = try c.decodeIfPresent([String: [KeyCombo]].self, forKey: .bindings) {
            var b: [Command: [KeyCombo]] = [:]
            for (name, combos) in raw { if let cmd = Command(name: name) { b[cmd] = combos } }
            let taken = decoder.userInfo[.arrowsTakenBySystem] as? Bool ?? Config.systemTakesArrows
            bindings = Config.migrate(b, from: version, arrowsTaken: taken)
            // On macOS 13 and 14 the version 1 shortcuts stay, and so does version 1. After an upgrade to
            // macOS 15 the migration then runs once.
            version = version < 2 && !taken ? version : Config.currentVersion
        } else {
            bindings = d.bindings
            version = Config.currentVersion
        }
    }

    /// Brings saved shortcuts up to date.
    /// - Version 1, on macOS 15 and later (`arrowsTaken`): removes the old ⌃⌥⇧ + arrow move defaults. macOS
    ///   takes them, so they never work. The store saves the result once, so a combo that the user adds again
    ///   later is not removed.
    /// - Every version: a command that is not in the file is newer than the file. It gets its default
    ///   shortcuts, except combos that the file already uses for another command. A command the user
    ///   cleared is in the file with an empty list, and stays empty.
    public static func migrate(_ saved: [Command: [KeyCombo]], from version: Int, arrowsTaken: Bool) -> [Command: [KeyCombo]] {
        var b = saved
        if version < 2, arrowsTaken {
            let cos: KeyModifiers = [.control, .option, .shift]
            let removed: [Command: UInt16] = [.moveLeft: KeyCode.left, .moveRight: KeyCode.right,
                                              .moveUp: KeyCode.up, .moveDown: KeyCode.down]
            for (cmd, key) in removed { b[cmd]?.removeAll { $0 == KeyCombo(key, cos) } }
        }
        let defaults = DefaultBindings.make()
        var used = Set(b.values.joined())
        for cmd in defaults.keys.sorted(by: { $0.name < $1.name }) where b[cmd] == nil {
            let fresh = (defaults[cmd] ?? []).filter { !used.contains($0) }
            b[cmd] = fresh
            used.formUnion(fresh)
        }
        return b
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(layout, forKey: .layout)
        try c.encode(animation, forKey: .animation)
        try c.encode(gestures, forKey: .gestures)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(behavior, forKey: .behavior)
        try c.encode(metrics, forKey: .metrics)
        try c.encode(disabledDisplays.sorted(), forKey: .disabledDisplays)
        try c.encode(rules, forKey: .rules)
        try c.encode(Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.name, $0.value) }), forKey: .bindings)
    }

    public func rule(for bundleID: String) -> AppRule? { rules.first { $0.bundleID == bundleID } }

    public static func decode(_ data: Data, arrowsTaken: Bool = Config.systemTakesArrows) throws -> Config {
        let d = JSONDecoder()
        d.userInfo[.arrowsTakenBySystem] = arrowsTaken
        return try d.decode(Config.self, from: data)
    }

    /// The `version` written in the file. nil when the file has none: then it is read as the current version.
    public static func fileVersion(_ data: Data) -> Int? {
        struct V: Decodable { var version: Int? }
        return (try? JSONDecoder().decode(V.self, from: data))?.version
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
