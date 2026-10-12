import AppKit
import CoreGraphics
import Foundation
import StripleCore

/// A display as the engine uses it: identity plus geometry in AX coordinates (top-left origin, y down).
struct EngineDisplay: Equatable {
    var uuid: String
    var cgID: CGDirectDisplayID
    var name: String
    var geometry: DisplayGeometry
}

enum DisplayGeometryBuilder {
    /// Converts AppKit screen rects (bottom-left origin of the primary display) to AX geometry and finds
    /// the neighbours of each display. `primaryHeight` is the height of the display with the menu bar.
    static func make(screens: [(frame: CGRect, visible: CGRect)], primaryHeight: CGFloat) -> [DisplayGeometry] {
        func flip(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        let frames = screens.map { flip($0.frame) }
        return screens.indices.map { i in
            let f = frames[i]
            let others = frames.indices.filter { $0 != i }.map { frames[$0] }
            let tolerance: CGFloat = 2
            func overlapsVertically(_ o: CGRect) -> Bool { o.minY < f.maxY - tolerance && o.maxY > f.minY + tolerance }
            func overlapsHorizontally(_ o: CGRect) -> Bool { o.minX < f.maxX - tolerance && o.maxX > f.minX + tolerance }
            return DisplayGeometry(
                frame: f,
                usable: flip(screens[i].visible),
                neighborLeft: others.contains { abs($0.maxX - f.minX) <= tolerance && overlapsVertically($0) },
                neighborRight: others.contains { abs($0.minX - f.maxX) <= tolerance && overlapsVertically($0) },
                neighborBelow: others.contains { abs($0.minY - f.maxY) <= tolerance && overlapsHorizontally($0) })
        }
    }

    @MainActor
    static func current() -> [EngineDisplay] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let geometry = make(screens: screens.map { ($0.frame, $0.visibleFrame) }, primaryHeight: primary.frame.height)
        return zip(screens, geometry).compactMap { screen, g in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return EngineDisplay(uuid: Displays.uuid(for: id), cgID: id, name: screen.localizedName, geometry: g)
        }
    }
}

/// The current Space of each display. Uses private SkyLight calls (as every Spaces-aware window manager does),
/// loaded with dlsym. Without them every display reports Space 0 and Striple still works, with one strip per display.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static func load<T>(_ name: String, as: T.Type) -> T? {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private static let mainConnection = load("CGSMainConnectionID", as: MainConnection.self)
    private static let currentSpace = load("CGSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)
    private static let spacesForWindows = load("CGSCopySpacesForWindows", as: SpacesForWindows.self)
    private static let displaySpaces = load("CGSCopyManagedDisplaySpaces", as: DisplaySpaces.self)

    static var available: Bool { mainConnection != nil && currentSpace != nil }

    static func current(displayUUID: String) -> UInt64 {
        guard let c = mainConnection, let s = currentSpace else { return 0 }
        return s(c(), displayUUID as CFString)
    }

    /// Every Space that exists, by display identifier ("Main" when displays do not have separate Spaces).
    /// Empty when unknown.
    static func all() -> [String: Set<UInt64>] {
        guard let c = mainConnection, let f = displaySpaces,
              let list = f(c())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var out: [String: Set<UInt64>] = [:]
        for d in list {
            guard let id = d["Display Identifier"] as? String else { continue }
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            out[id, default: []].formUnion(spaces)
        }
        return out
    }

    /// The Spaces a window is on. Empty when unknown.
    static func spaces(of window: WindowID) -> [UInt64] {
        guard let c = mainConnection, let f = spacesForWindows else { return [] }
        let ids = [NSNumber(value: window)] as CFArray
        // Mask 7: current, other and user Spaces.
        guard let arr = f(c(), 7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return arr.map(\.uint64Value)
    }
}

/// Whether the login window covers the session. AX lists no windows of other apps then.
enum ScreenLock {
    static var isLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true
    }
}

/// IDs of all windows that exist, on any Space. Used to drop windows that closed without a notification.
enum WindowList {
    static func allWindowIDs() -> Set<WindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<WindowID>()
        ids.reserveCapacity(list.count)
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let n = w[kCGWindowNumber as String] as? NSNumber { ids.insert(n.uint32Value) }
        }
        return ids
    }
}
