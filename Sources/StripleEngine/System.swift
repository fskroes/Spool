import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import StripleCore

/// Accessibility permission.
public enum Permissions {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt that adds Striple to the Accessibility list.
    public static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openSettings(_ pane: MacSetupCheck.Pane) {
        let urls: [MacSetupCheck.Pane: String] = [
            .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            .trackpad: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
            .pointerControl: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?PointerControl",
            .desktopDock: "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
        ]
        guard let s = urls[pane], let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Reads the macOS settings that Mac Setup checks. Read-only: Striple never changes macOS settings.
public enum MacSetupProbe {
    public static func inputs(swipeFingers: SwipeFingers) -> MacSetupInputs {
        let trackpad = "com.apple.AppleMultitouchTrackpad"
        let bluetooth = "com.apple.driver.AppleBluetoothMultitouch.trackpad"
        func int(_ key: String, _ domains: [String]) -> Int? {
            for d in domains {
                if let v = CFPreferencesCopyAppValue(key as CFString, d as CFString) as? NSNumber { return v.intValue }
            }
            return nil
        }
        func bool(_ key: String, _ domain: String) -> Bool? {
            (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.boolValue
        }
        let threeDrag = int("TrackpadThreeFingerDrag", [trackpad, bluetooth]).map { $0 != 0 }
        return MacSetupInputs(
            accessibilityTrusted: Permissions.isTrusted,
            swipeFingers: swipeFingers,
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            fourFingerHorizSwipe: int("TrackpadFourFingerHorizSwipeGesture", [trackpad, bluetooth]),
            threeFingerHorizSwipe: int("TrackpadThreeFingerHorizSwipeGesture", [trackpad, bluetooth]),
            threeFingerDrag: threeDrag,
            mruSpaces: bool("mru-spaces", "com.apple.dock"),
            spansDisplays: bool("spans-displays", "com.apple.spaces"),
            stageManager: bool("GloballyEnabled", "com.apple.WindowManager"),
            tilingByEdgeDrag: bool("EnableTilingByEdgeDrag", "com.apple.WindowManager"),
            tilingByTopEdgeDrag: bool("EnableTopTilingByEdgeDrag", "com.apple.WindowManager"),
            tilingOptionAccelerator: bool("EnableTilingOptionAccelerator", "com.apple.WindowManager"),
            conflictingApps: runningWindowManagers())
    }

    public static func checks(swipeFingers: SwipeFingers) -> [MacSetupCheck] {
        MacSetup.evaluate(inputs(swipeFingers: swipeFingers))
    }

    public static func runningWindowManagers() -> [String] {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = KnownWindowManagers.bundleIDs[id] { names.insert(name) }
            if let exe = app.executableURL?.lastPathComponent, let name = KnownWindowManagers.processNames[exe] { names.insert(name) }
        }
        return names.sorted()
    }
}

/// A connected display, as the settings UI shows it.
public struct DisplayDescriptor: Equatable, Identifiable, Sendable {
    /// Stable across reboots and reconnects (the display UUID). Used in `Config.disabledDisplays`.
    public var id: String
    public var name: String
    public var cgID: CGDirectDisplayID
    /// AppKit coordinates (bottom-left origin).
    public var frame: CGRect
    public var isMain: Bool
}

public enum Displays {
    @MainActor
    public static func current() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let cgID = CGDirectDisplayID(number.uint32Value)
            return DisplayDescriptor(id: uuid(for: cgID), name: screen.localizedName, cgID: cgID,
                                     frame: screen.frame, isMain: CGDisplayIsMain(cgID) != 0)
        }
    }

    public static func uuid(for display: CGDirectDisplayID) -> String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return "display-\(display)" }
        return CFUUIDCreateString(nil, cf) as String
    }
}
