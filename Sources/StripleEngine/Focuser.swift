import AppKit
import ApplicationServices
import Foundation
import StripleCore

/// Brings one window to the front and gives it keyboard focus.
///
/// `NSRunningApplication.activate` cannot pick a window, and since macOS 14 a background agent cannot use it to
/// activate another app. Like other macOS window managers, Striple uses the SkyLight process calls (loaded with
/// dlsym) to make the window key, and falls back to the public API when they are missing.
@MainActor
enum Focuser {
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static func load<T>(_ name: String, as: T.Type) -> T? {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private static let getPSN = load("GetProcessForPID", as: GetPSN.self)
    private static let setFront = load("_SLPSSetFrontProcessWithOptions", as: SetFront.self)
    private static let postRecord = load("SLPSPostEventRecordTo", as: PostRecord.self)

    /// kCPSUserGenerated: the switch counts as the user's, so macOS does not refuse it.
    private static let userGenerated: UInt32 = 0x200

    /// False when it used the public fallback (the SkyLight calls are missing or refused the pid).
    @discardableResult
    static func focus(window id: WindowID, pid: pid_t, element: AXUIElement) -> Bool {
        var psn = ProcessSerialNumber()
        let fast: Bool
        if let getPSN, let setFront, getPSN(pid, &psn) == noErr {
            _ = setFront(&psn, id, userGenerated)
            makeKey(&psn, id)
            fast = true
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
            fast = false
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AX.raise(element)
        return fast
    }

    /// Sends the two "make key window" event records that the window server sends on a click.
    private static func makeKey(_ psn: inout ProcessSerialNumber, _ id: WindowID) {
        guard let postRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        withUnsafeBytes(of: id) { raw in for (i, b) in raw.enumerated() { bytes[0x3C + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postRecord(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postRecord(&psn, $0.baseAddress!) }
    }
}
