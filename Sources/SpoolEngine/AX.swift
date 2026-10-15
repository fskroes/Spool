import AppKit
import ApplicationServices
import Foundation
import SpoolCore

/// Thin, typed access to the Accessibility API. Every call can fail when the app is busy or quits,
/// so getters return optionals and setters return success.
enum AX {
    /// AX calls to a hung app block the caller. Keep the wait short: a missed frame is better than a frozen strip.
    static let messagingTimeout: Float = 0.25

    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// `_AXUIElementGetWindow` is not public, but every window manager on macOS uses it. Loaded lazily with dlsym
    /// so a missing symbol degrades (no window IDs) instead of failing to launch.
    static let getWindowFn: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    /// Sets the timeout on the system-wide element. That is the global timeout for every AX call of this
    /// process, also for window elements from kAXWindows and from notifications. A timeout set on one element
    /// applies to that element only (AXUIElement.h), so `app(_:)` alone does not cover windows.
    @discardableResult
    static func setGlobalTimeout() -> AXError {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    /// The windows of an app. nil when the app does not answer (timeout), so the caller can tell a hung app
    /// from an app without windows.
    static func windows(of pid: pid_t) -> [AXUIElement]? {
        var v: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &v)
        if r == .cannotComplete { return nil }
        return (v as? [AnyObject])?.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        } ?? []
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, messagingTimeout)
        return e
    }

    static func windowID(_ e: AXUIElement) -> WindowID? {
        guard let fn = getWindowFn else { return nil }
        var id: CGWindowID = 0
        return fn(e, &id) == .success && id != 0 ? id : nil
    }

    static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? { value(e, attr) as? String }
    static func bool(_ e: AXUIElement, _ attr: String) -> Bool? { (value(e, attr) as? NSNumber)?.boolValue }

    static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ e: AXUIElement, _ attr: String) -> [AXUIElement] {
        (value(e, attr) as? [AnyObject])?.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        } ?? []
    }

    static func point(_ e: AXUIElement) -> CGPoint? {
        guard let v = value(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ e: AXUIElement) -> CGSize? {
        guard let v = value(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = point(e), let s = size(e) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func setPosition(_ e: AXUIElement, _ p: CGPoint) -> AXError {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v)
    }

    @discardableResult
    static func setSize(_ e: AXUIElement, _ s: CGSize) -> AXError {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v)
    }

    @discardableResult
    static func set(_ e: AXUIElement, _ attr: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(e, attr as CFString, value as CFBoolean)
    }

    static func isSettable(_ e: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, attr as CFString, &settable) == .success && settable.boolValue
    }

    static func raise(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXRaiseAction as CFString) }

    static func pid(_ e: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(e, &pid) == .success ? pid : nil
    }

    /// Facts that decide if a window is tiled, floated or ignored.
    static func traits(_ e: AXUIElement, bundleID: String, isOwnApp: Bool) -> WindowTraits {
        let zoom = element(e, kAXZoomButtonAttribute).flatMap { bool($0, kAXEnabledAttribute) }
        return WindowTraits(bundleID: bundleID,
                            role: string(e, kAXRoleAttribute) ?? "",
                            subrole: string(e, kAXSubroleAttribute) ?? "",
                            isResizable: isSettable(e, kAXSizeAttribute),
                            zoomButtonEnabled: zoom,
                            isFullscreen: bool(e, "AXFullScreen") ?? false,
                            isMinimized: bool(e, kAXMinimizedAttribute) ?? false,
                            isOwnApp: isOwnApp)
    }
}
