import CoreGraphics
import Foundation

/// The bundle ID of the E2E test window app. Striple matches apps by bundle ID, so the runner wraps the
/// test binary in an app bundle with this ID and passes it in `STRIPLE_MANAGE_ONLY`.
public enum E2EIDs {
    public static let windowsBundleID = "com.fskroes.Striple.e2e-windows"
    public static let windowsAppName = "StripleE2EWindows"
    public static let windowsExecutable = "striple-e2e-windows"
}

/// One window of the test app, in global top-left coordinates (the space of CGWindowList and AX:
/// origin at the top-left of the main display, y down).
public struct ReportedWindow: Codable, Equatable, Sendable {
    public var title: String
    /// `NSWindow.windowNumber`, which is the CGWindowID that Striple reports in `state --json`.
    public var number: Int
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(title: String, number: Int, x: Double, y: Double, w: Double, h: Double) {
        self.title = title
        self.number = number
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(title: String, number: Int, frame: CGRect) {
        self.init(title: title, number: number, x: Double(frame.minX), y: Double(frame.minY),
                  w: Double(frame.width), h: Double(frame.height))
    }

    public var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// The file the test app writes every 100 ms.
public struct WindowReport: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Goes up by one with every write. The runner uses it to know that a report is new.
    public var seq: Int
    /// Commands from the commands file that the app has run.
    public var commandsDone: Int
    public var windows: [ReportedWindow]
    /// True when the test app is the active (frontmost) app.
    public var active: Bool
    /// The window number of the key window, if any.
    public var key: Int?

    public init(pid: Int32, seq: Int, commandsDone: Int, windows: [ReportedWindow], active: Bool = false, key: Int? = nil) {
        self.pid = pid
        self.seq = seq
        self.commandsDone = commandsDone
        self.windows = windows
        self.active = active
        self.key = key
    }

    /// True when `number` has the keyboard focus of the system: the app is frontmost and the window is key.
    /// Striple acts on the system focus (for example `toggle-float`), not only on its own idea of focus.
    public func hasSystemFocus(_ number: Int) -> Bool { active && key == number }

    public func window(number: Int) -> ReportedWindow? { windows.first { $0.number == number } }
    public func window(title: String) -> ReportedWindow? { windows.first { $0.title == title } }
}

public enum Coordinates {
    /// AppKit rect (origin bottom-left of the main display, y up) to global top-left coordinates.
    /// `primaryHeight` is the height of the main display (the one with the menu bar, `NSScreen.screens[0]`).
    public static func topLeft(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Commands the runner sends to the test app. One per line in the commands file; the app runs each new
/// complete line once.
public enum WindowCommand: Equatable, Sendable {
    case open
    case close(title: String)
    case quit

    public var line: String {
        switch self {
        case .open: return "open"
        case .close(let title): return "close \(title)"
        case .quit: return "quit"
        }
    }

    public init?(line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "open" { self = .open; return }
        if t == "quit" { self = .quit; return }
        if t.hasPrefix("close ") {
            let title = String(t.dropFirst("close ".count)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            self = .close(title: title)
            return
        }
        return nil
    }

    /// The complete lines in the file text. A last line without a newline is still being written: left out.
    public static func completeLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        lines.removeLast()
        return lines
    }
}
