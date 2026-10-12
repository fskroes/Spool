import AppKit
import StripleCore

/// Only one Striple runs at a time. launchd can start one while the user opens another.
enum SingleInstance {
    /// Posted by a second instance so the first one opens its settings window.
    static let reopenNotification = Notification.Name("com.fskroes.Striple.reopen")

    /// The open file that holds the lock. It stays open for the life of the process; the kernel frees the lock
    /// when the process ends, also after a crash.
    private static var lockFD: Int32 = -1

    static var lockFile: URL { StriplePaths.supportDirectory.appendingPathComponent("instance.lock") }

    /// Takes the instance lock. Exactly one of two processes that start at the same time gets it.
    /// Returns false when another process holds it.
    static func acquire(at url: URL = lockFile) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        // Without a lock file (read-only home) there is no arbiter; run rather than refuse to start.
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    /// The other running Striple, matched by bundle ID or, without a bundle, by executable path.
    static func other() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != me }
        }
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != me && $0.executableURL?.resolvingSymlinksInPath() == exe
        }
    }

    /// True when launchd started this process from the LaunchAgent (at login or after a crash).
    static var startedByLaunchAgent: Bool {
        let service = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return service.hasPrefix(LoginItem.agentPlistName.replacingOccurrences(of: ".plist", with: ""))
    }

    /// Hands over to the running instance and ends this process with status 0, so launchd does not restart it.
    static func handOver(to other: NSRunningApplication?) -> Never {
        if !startedByLaunchAgent {
            DistributedNotificationCenter.default().postNotificationName(reopenNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            other?.activate(options: [])
        }
        NSLog("Striple: another instance is running (pid %d). This one quits.", other?.processIdentifier ?? -1)
        exit(0)
    }
}
