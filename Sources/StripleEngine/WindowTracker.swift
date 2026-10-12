import AppKit
import ApplicationServices
import Foundation
import StripleCore

/// What the tracker reports to the engine. Always delivered on the main thread.
enum TrackerEvent {
    case appLaunched(pid_t)
    case appTerminated(pid_t)
    case appActivated(pid_t)
    case appHidden(pid_t)
    case appShown(pid_t)
    case windowCreated(AXUIElement, pid_t)
    case windowDestroyed(AXUIElement, pid_t)
    case focusedWindowChanged(pid_t)
    case windowMoved(AXUIElement, pid_t)
    case windowResized(AXUIElement, pid_t)
    case windowMinimized(AXUIElement, pid_t)
    case windowDeminimized(AXUIElement, pid_t)
    case titleChanged(AXUIElement, pid_t)
    case spaceChanged
    case displaysChanged
    case didWake
    /// The screen was unlocked or the user switched back to this login session.
    case sessionResumed
}

/// Watches apps and windows with AX observers and NSWorkspace notifications.
@MainActor
final class WindowTracker {
    private final class AppWatch {
        let pid: pid_t
        let observer: AXObserver
        let app: AXUIElement
        var windows: [AXUIElement] = []
        init(pid: pid_t, observer: AXObserver, app: AXUIElement) {
            self.pid = pid
            self.observer = observer
            self.app = app
        }
    }

    private var watches: [pid_t: AppWatch] = [:]
    private var retries: [pid_t: Int] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let onEvent: (TrackerEvent) -> Void
    private let log: (String) -> Void

    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification]

    init(onEvent: @escaping (TrackerEvent) -> Void, log: @escaping (String) -> Void) {
        self.onEvent = onEvent
        self.log = log
    }

    var watchedPIDs: [pid_t] { Array(watches.keys) }

    func appElement(_ pid: pid_t) -> AXUIElement? { watches[pid]?.app }

    /// Apps whose windows Striple manages: regular apps. Striple itself is left out: its own windows float, and
    /// Accessibility calls into the own process from the main thread can block.
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    static func manageableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isManageable)
    }

    static func isManageable(_ app: NSRunningApplication) -> Bool {
        Policy.isManageableApp(policy: app.activationPolicy, pid: app.processIdentifier, ownPID: getpid(), terminated: app.isTerminated)
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ make: @escaping (NSRunningApplication?) -> TrackerEvent?) {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let e = make(app) else { return }
                    if case .appLaunched(let pid) = e { self.watch(pid) }
                    if case .appTerminated(let pid) = e { self.unwatch(pid) }
                    self.onEvent(e)
                }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { app in
            guard let app, Self.isManageable(app) else { return nil }
            return .appLaunched(app.processIdentifier)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { $0.map { .appTerminated($0.processIdentifier) } }
        on(NSWorkspace.didActivateApplicationNotification) { $0.map { .appActivated($0.processIdentifier) } }
        on(NSWorkspace.didHideApplicationNotification) { $0.map { .appHidden($0.processIdentifier) } }
        on(NSWorkspace.didUnhideApplicationNotification) { $0.map { .appShown($0.processIdentifier) } }
        on(NSWorkspace.activeSpaceDidChangeNotification) { _ in .spaceChanged }
        on(NSWorkspace.didWakeNotification) { _ in .didWake }
        on(NSWorkspace.sessionDidBecomeActiveNotification) { _ in .sessionResumed }
        // While the screen is locked, AX shows no real windows. The unlock is the moment to look again.
        tokens.append(DistributedNotificationCenter.default().addObserver(forName: Self.screenUnlocked, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent(.sessionResumed) }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent(.displaysChanged) }
        })
        for app in Self.manageableApps() { watch(app.processIdentifier) }
    }

    func stop() {
        for t in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
            NotificationCenter.default.removeObserver(t)
            DistributedNotificationCenter.default().removeObserver(t)
        }
        tokens.removeAll()
        for pid in Array(watches.keys) { unwatch(pid) }
        retries.removeAll()
    }

    /// Creates the observer for an app. Apps that just launched often do not answer AX yet: try again a few times.
    func watch(_ pid: pid_t) {
        guard watches[pid] == nil else { return }
        switch makeWatch(pid) {
        case .success(let w): install(w)
        case .failure(let why): scheduleRetry(pid, reason: why.reason)
        }
    }

    struct WatchFailure: Error { let reason: String }

    /// An observer with the app notifications registered, not yet on the run loop.
    private func makeWatch(_ pid: pid_t) -> Result<AppWatch, WatchFailure> {
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &observer) == .success, let observer else {
            return .failure(WatchFailure(reason: "AXObserverCreate failed"))
        }
        let app = AX.app(pid)
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
        var registered = 0
        for n in Self.appNotifications where AXObserverAddNotification(observer, app, n as CFString, refcon) == .success {
            registered += 1
        }
        guard registered > 0 else { return .failure(WatchFailure(reason: "app does not answer Accessibility yet")) }
        return .success(AppWatch(pid: pid, observer: observer, app: app))
    }

    private func install(_ w: AppWatch) {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(w.observer), .defaultMode)
        watches[w.pid] = w
        retries[w.pid] = nil
    }

    func unwatch(_ pid: pid_t) {
        guard let w = watches.removeValue(forKey: pid) else { return }
        drop(w)
    }

    private func drop(_ w: AppWatch) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(w.observer), .defaultMode)
    }

    /// Re-creates the observer, for example after AX errors that suggest it died. False when the app does not
    /// answer: then the old observer stays, because a hung app also refuses the new one, and dropping the old one
    /// first would leave its windows without notifications. The caller observes the windows again on true.
    @discardableResult
    func rewatch(_ pid: pid_t) -> Bool {
        guard watches[pid] != nil else {
            watch(pid)
            return watches[pid] != nil
        }
        guard let plan = Self.replace(old: watches[pid], make: { try? makeWatch(pid).get() }) else { return false }
        watches[pid] = nil
        if let old = plan.drop { drop(old) }
        install(plan.install)
        return true
    }

    /// The new watch is made first. nil (keep the old one) when it cannot be made; else the watch to install
    /// and the old one to drop.
    nonisolated static func replace<W>(old: W?, make: () -> W?) -> (install: W, drop: W?)? {
        guard let fresh = make() else { return nil }
        return (fresh, old)
    }

    /// Adds the per-window notifications (moved, resized, destroyed...).
    func observe(window: AXUIElement, pid: pid_t) {
        guard let w = watches[pid], !w.windows.contains(where: { CFEqual($0, window) }) else { return }
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
        for n in Self.windowNotifications { AXObserverAddNotification(w.observer, window, n as CFString, refcon) }
        w.windows.append(window)
    }

    func forget(window: AXUIElement, pid: pid_t) {
        guard let w = watches[pid] else { return }
        w.windows.removeAll { CFEqual($0, window) }
        for n in Self.windowNotifications { AXObserverRemoveNotification(w.observer, window, n as CFString) }
    }

    private func scheduleRetry(_ pid: pid_t, reason: String) {
        let n = (retries[pid] ?? 0) + 1
        guard n <= 6, NSRunningApplication(processIdentifier: pid) != nil else {
            if n > 6 { log("tracker: gave up on pid \(pid): \(reason)") }
            retries[pid] = nil
            return
        }
        retries[pid] = n
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(n)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.watches[pid] == nil else { return }
                self.watch(pid)
                if self.watches[pid] != nil { self.onEvent(.appLaunched(pid)) }
            }
        }
    }

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        let pid = pid_t(Int(bitPattern: refcon))
        let name = notification as String
        MainActor.assumeIsolated {
            guard let tracker = WindowTracker.current else { return }
            let e: TrackerEvent?
            switch name {
            case kAXWindowCreatedNotification: e = .windowCreated(element, pid)
            case kAXUIElementDestroyedNotification: e = .windowDestroyed(element, pid)
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification: e = .focusedWindowChanged(pid)
            case kAXWindowMovedNotification: e = .windowMoved(element, pid)
            case kAXWindowResizedNotification: e = .windowResized(element, pid)
            case kAXWindowMiniaturizedNotification: e = .windowMinimized(element, pid)
            case kAXWindowDeminiaturizedNotification: e = .windowDeminimized(element, pid)
            case kAXTitleChangedNotification: e = .titleChanged(element, pid)
            default: e = nil
            }
            if let e { tracker.onEvent(e) }
        }
    }

    /// The tracker of the running engine. AX callbacks are C functions without context beyond the pid.
    static var current: WindowTracker?
}
