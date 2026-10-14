import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Security
import StripleCore

/// Accessibility permission.
public enum Permissions {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt that adds Striple to the Accessibility list.
    public static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The `tccutil` arguments that remove Striple's own Accessibility entry. Nil without a bundle ID:
    /// `tccutil reset Accessibility` with no bundle ID would remove the entry of every app.
    public static func resetArguments(bundleID: String?) -> [String]? {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return ["reset", "Accessibility", id]
    }

    /// True when a designated requirement is only cdhashes: the code is signed ad hoc (or not signed,
    /// and the linker signed it ad hoc). An Accessibility entry made for such a build matches no later build.
    public static func isCdhashOnly(requirement: String) -> Bool {
        let r = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.hasPrefix("cdhash ") && !r.contains("certificate") && !r.contains("anchor")
    }

    /// The designated requirement of this process as text, or nil when macOS cannot read it.
    public static func ownRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// Removes Striple's own Accessibility entry, then shows the prompt again. See `PermissionReset`.
    @MainActor
    public static func resetAndPrompt() {
        PermissionReset.shared.run(bundleID: Bundle.main.bundleIdentifier)
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

/// Reads the macOS settings that Mac Setup checks. Read-only. The one change Striple makes is
/// `Permissions.resetAndPrompt`, and only when the user clicks Reset Permission.
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

/// Removes Striple's own Accessibility entry, then shows the prompt again.
/// Why: macOS stores the code requirement of the build that was on screen when the entry was made.
/// Turning the switch off and on keeps it. An entry made for an ad hoc build stores cdhashes, so
/// no later build matches, and the switch shows on while `AXIsProcessTrusted()` is false.
/// Only a new entry stores the requirement of this build. Needs no admin password.
/// On an ad hoc build it asks first: a new entry for it stores cdhashes again.
/// The effects are injected, so the tests can run the full flow with no tccutil and no alert.
@MainActor
public final class PermissionReset {
    public struct Effects {
        public var requirement: @MainActor () -> String?
        public var confirm: @MainActor (_ title: String, _ text: String, _ button: String) -> Bool
        public var alert: @MainActor (_ title: String, _ text: String) -> Void
        /// Runs tccutil with the arguments, returns its exit status (-1 when it did not start). Off the main thread.
        public var tccutil: @Sendable ([String]) -> Int32
        /// Runs the work off the main thread, then the completion on the main thread.
        public var offMain: (@escaping @Sendable () -> Int32, @escaping @MainActor @Sendable (Int32) -> Void) -> Void
        public var prompt: @MainActor () -> Void
        public var openSettings: @MainActor () -> Void
        public var log: @Sendable (String) -> Void

        public init(requirement: @escaping @MainActor () -> String?,
                    confirm: @escaping @MainActor (String, String, String) -> Bool,
                    alert: @escaping @MainActor (String, String) -> Void,
                    tccutil: @escaping @Sendable ([String]) -> Int32,
                    offMain: @escaping (@escaping @Sendable () -> Int32, @escaping @MainActor @Sendable (Int32) -> Void) -> Void,
                    prompt: @escaping @MainActor () -> Void,
                    openSettings: @escaping @MainActor () -> Void,
                    log: @escaping @Sendable (String) -> Void) {
            self.requirement = requirement
            self.confirm = confirm
            self.alert = alert
            self.tccutil = tccutil
            self.offMain = offMain
            self.prompt = prompt
            self.openSettings = openSettings
            self.log = log
        }
    }

    public static let shared = PermissionReset(effects: .live)

    private let effects: Effects
    public private(set) var running = false

    public init(effects: Effects) { self.effects = effects }

    public func run(bundleID: String?) {
        guard !running else {
            effects.log("permissions: Reset Permission is running already, click ignored")
            return
        }
        guard let args = Permissions.resetArguments(bundleID: bundleID) else {
            effects.log("permissions: no bundle ID, the Accessibility entry was not reset")
            effects.alert("Striple cannot reset its permission",
                          "This copy of Striple has no bundle ID. Open Striple.app, not the bare binary.")
            return
        }
        if let requirement = effects.requirement(), Permissions.isCdhashOnly(requirement: requirement) {
            let reset = effects.confirm("This build is signed ad hoc",
                                        "A new permission for this build stops working after the next build, while the switch still shows on. Then click Reset Permission again. To keep the permission after a rebuild, sign Striple with a stable identity (docs/INSTALL.md, \"Keep the Accessibility permission after a rebuild\").",
                                        "Reset Anyway")
            effects.log("permissions: ad hoc build (\(requirement)), reset \(reset ? "confirmed" : "cancelled")")
            guard reset else { return }
        }
        running = true
        let tccutil = effects.tccutil
        effects.offMain({ tccutil(args) }) { [self] status in
            running = false
            let command = "tccutil " + args.joined(separator: " ")
            effects.log("permissions: \(command) exited \(status)")
            guard status == 0 else {
                effects.alert("Striple could not reset its permission",
                              "Run this command in Terminal, then click Request Permission in Settings > Mac Setup:\n\n\(command)")
                return
            }
            effects.prompt()
            effects.openSettings()
        }
    }
}

extension PermissionReset.Effects {
    public static var live: Self {
        Self(requirement: { Permissions.ownRequirement() },
             confirm: { title, text, button in
                 let a = NSAlert()
                 a.messageText = title
                 a.informativeText = text
                 a.alertStyle = .warning
                 a.addButton(withTitle: button)
                 a.addButton(withTitle: "Cancel")
                 NSApp.activate(ignoringOtherApps: true)
                 return a.runModal() == .alertFirstButtonReturn
             },
             alert: { title, text in
                 let a = NSAlert()
                 a.messageText = title
                 a.informativeText = text
                 a.alertStyle = .warning
                 NSApp.activate(ignoringOtherApps: true)
                 a.runModal()
             },
             tccutil: { args in
                 let p = Process()
                 p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                 p.arguments = args
                 p.standardOutput = FileHandle.nullDevice
                 p.standardError = FileHandle.nullDevice
                 do {
                     try p.run()
                     p.waitUntilExit()
                     return p.terminationStatus
                 } catch {
                     EngineLog.shared.log("permissions: tccutil did not start: \(error.localizedDescription)")
                     return -1
                 }
             },
             offMain: { work, done in
                 DispatchQueue.global(qos: .userInitiated).async {
                     let status = work()
                     DispatchQueue.main.async { MainActor.assumeIsolated { done(status) } }
                 }
             },
             prompt: { Permissions.prompt() },
             openSettings: { Permissions.openSettings(.accessibility) },
             log: { EngineLog.shared.log($0) })
    }
}
