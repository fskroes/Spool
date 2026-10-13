import AppKit
import ApplicationServices
import Foundation
import StripleCore
import StripleE2EKit

/// Paths and settings for one run.
struct RunConfig {
    var app: URL
    var windowsBinary: URL
    var bundleDir: URL
    var outDir: URL
    var windowCount = 3
    /// `--animations`: the test Striple's `animation.enabled`, and the budget of scenario h.
    var animations = PerformanceBudget.Animations.on
}

enum E2EError: Error, CustomStringConvertible {
    case setup(String)
    var description: String {
        switch self { case .setup(let s): return s }
    }
}

/// Starts and talks to Striple and the test app. All waits poll; none sleeps for a fixed time to "be sure".
final class Harness {
    let config: RunConfig
    let home: URL
    let socket: String
    let reportFile: URL
    let commandsFile: URL
    private(set) var striple: Process?
    private(set) var windowsApp: Process?
    /// Guards `striple`, `windowsApp` and `stopping`. Cleanup can run on a signal queue while the main thread
    /// starts a process: a process starts only before cleanup began, and cleanup sees every process that started.
    private let lifecycle = NSLock()
    private var stopping = false
    private var logHandle: FileHandle?
    let layout = Config().layout

    /// Wall time of each CLI call that sent a command, in ms (process start included).
    private(set) var cliCommandMs: [Double] = []
    /// Time from a command to settled frames, in ms. A settle that reached its timeout adds its full time.
    private(set) var settleMs: [Double] = []
    /// Settles that reached their timeout.
    private(set) var settleTimeouts = 0
    /// `striple state` calls that returned a state. The managed-windows safety row needs at least one.
    private(set) var statesRead = 0
    /// Managed windows that are not test windows. Must stay empty.
    private(set) var foreignManaged: [String: String] = [:]
    /// Commands that were not sent because the test window did not get the focus. Each scenario fails on them.
    private(set) var focusFailures: [String] = []

    var cli: String { config.app.appendingPathComponent("Contents/Helpers/striple").path }
    var stripleBinary: String { config.app.appendingPathComponent("Contents/MacOS/Striple").path }

    init(config: RunConfig, home: URL) {
        self.config = config
        self.home = home
        socket = home.appendingPathComponent("striple.sock").path
        reportFile = config.outDir.appendingPathComponent("windows.json")
        commandsFile = config.outDir.appendingPathComponent("commands.txt")
        FileManager.default.createFile(atPath: config.outDir.appendingPathComponent("run.log").path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: config.outDir.appendingPathComponent("run.log"))
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        logHandle?.write(Data(line.utf8))
    }

    // MARK: Geometry

    /// The main display (with the menu bar), in top-left coordinates.
    func geometry() -> StripGeometry {
        let main = NSScreen.screens[0]
        let h = main.frame.height
        let g = layout
        let display = Coordinates.topLeft(main.frame, primaryHeight: h)
        let n = StripGeometry.neighbors(of: display, among: displayFrames())
        return StripGeometry(display: display,
                             visible: Coordinates.topLeft(main.visibleFrame, primaryHeight: h), innerGap: g.innerGap,
                             outerTop: g.outerGaps.top, outerBottom: g.outerGaps.bottom, outerLeft: g.outerGaps.left,
                             outerRight: g.outerGaps.right, sliver: g.parkedSliver, neighborLeft: n.left, neighborRight: n.right,
                             neighborBelow: n.below)
    }

    func displayFrames() -> [CGRect] {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { Coordinates.topLeft($0.frame, primaryHeight: h) }
    }

    // MARK: Test app

    /// Wraps the test binary in an ad hoc signed app bundle, so it has the test bundle ID.
    func makeWindowsBundle() throws -> URL {
        let fm = FileManager.default
        let app = config.bundleDir.appendingPathComponent("\(E2EIDs.windowsAppName).app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        if fm.fileExists(atPath: app.path) {
            // Replace only a test app bundle that the runner made, never another app with the same name.
            let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard plist?["CFBundleIdentifier"] as? String == E2EIDs.windowsBundleID else {
                throw E2EError.setup("\(app.path) exists and is not the test app (\(E2EIDs.windowsBundleID)). "
                                     + "Move it away or pass another --bundle-dir.")
            }
            try fm.removeItem(at: app)
        }
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(at: config.windowsBinary, to: macos.appendingPathComponent(E2EIDs.windowsExecutable))
        let plist: [String: Any] = [
            "CFBundleIdentifier": E2EIDs.windowsBundleID,
            "CFBundleName": E2EIDs.windowsAppName,
            "CFBundleExecutable": E2EIDs.windowsExecutable,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": false,
            "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Proc.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        guard sign.code == 0 else { throw E2EError.setup("codesign of the test app failed: \(sign.err)") }
        return app
    }

    func startWindowsApp(_ app: URL) throws {
        FileManager.default.createFile(atPath: commandsFile.path, contents: nil)
        try? FileManager.default.removeItem(at: reportFile)
        let exe = app.appendingPathComponent("Contents/MacOS/\(E2EIDs.windowsExecutable)").path
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !stopping else { throw E2EError.setup("the run was stopped before the test app started") }
        windowsApp = try Proc.start(exe, ["--count", "\(config.windowCount)", "--report", reportFile.path, "--commands", commandsFile.path],
                                    env: ProcessInfo.processInfo.environment, log: config.outDir.appendingPathComponent("windows-app.log"))
    }

    var windowsAppPID: Int32? { windowsApp.map(\.processIdentifier) }

    func frames() -> WindowReport? {
        guard let data = FileManager.default.contents(atPath: reportFile.path) else { return nil }
        return try? JSONDecoder().decode(WindowReport.self, from: data)
    }

    private var commandsSent = 0

    /// Sends a command to the test app and waits until it ran it.
    func send(_ command: WindowCommand, timeout: Double = 3) -> Bool {
        guard let h = try? FileHandle(forWritingTo: commandsFile) else { return false }
        _ = try? h.seekToEnd()
        h.write(Data((command.line + "\n").utf8))
        try? h.close()
        commandsSent += 1
        let want = commandsSent
        return poll(timeout: timeout) { (self.frames()?.commandsDone ?? 0) >= want }
    }

    // MARK: Striple

    func startStriple() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var c = Config()
        c.behavior.onboardingDone = true
        c.animation.enabled = config.animations == .on
        try c.encoded().write(to: home.appendingPathComponent("config.json"))
        var env = ProcessInfo.processInfo.environment
        env["STRIPLE_HOME"] = home.path
        env["STRIPLE_MANAGE_ONLY"] = E2EIDs.windowsBundleID
        env.removeValue(forKey: "STRIPLE_SOCKET")
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !stopping else { throw E2EError.setup("the run was stopped before Striple started") }
        striple = try Proc.start(stripleBinary, [], env: env, log: config.outDir.appendingPathComponent("striple-stdout.log"))
    }

    /// Runs the CLI against the test socket.
    @discardableResult
    func run(_ args: [String], timeout: Double = 15) -> ProcResult {
        var env = ProcessInfo.processInfo.environment
        env["STRIPLE_SOCKET"] = socket
        env.removeValue(forKey: "STRIPLE_HOME")
        return Proc.run(cli, args, env: env, timeout: timeout)
    }

    func ping() -> Bool { run(["ping"], timeout: 3).code == 0 }

    func state() -> EngineState? {
        let r = run(["state", "--json"])
        guard r.code == 0, let resp = try? JSONDecoder().decode(IPCResponse.self, from: Data(r.out.utf8)), let s = resp.state else { return nil }
        statesRead += 1
        // The safety net next to the CGWindowList check: Striple may only manage test windows.
        for w in s.displays.flatMap({ $0.columns.joined() }) + s.floating where w.bundleID != E2EIDs.windowsBundleID {
            foreignManaged["\(w.id)"] = "\(w.bundleID) \"\(w.title)\""
        }
        return s
    }

    func stats() -> EngineStats? {
        let r = run(["stats", "--json"])
        guard r.code == 0, let resp = try? JSONDecoder().decode(IPCResponse.self, from: Data(r.out.utf8)) else { return nil }
        return resp.stats
    }

    /// Sends a Striple command. Strip commands go to the strip of the focused window, or of the display under the
    /// mouse when Striple has no focused window (the user clicked another app). So first make sure a test
    /// window has Striple's focus. With `repair: false` (scenario b checks the focus itself) a window without
    /// the focus is a failure: the command is not sent and the focus is not given back.
    func command(_ name: String, focus: UInt32? = nil, repair: Bool = true) -> ProcResult {
        if !repair, let want = focus ?? currentTestFocus(), !hasFocus(want) {
            let why = "window \(want) did not have the focus before `\(name)` (frontmost \(frontmostApp()))"
            focusFailures.append(why)
            log("striple \(name): not sent, \(why)")
            return ProcResult(code: -1, out: "", err: why, ms: 0)
        }
        if let want = focus ?? currentTestFocus(), !hasFocus(want) {
            // Striple acts on the system focus (for example toggle-float). When the user works in another app,
            // give the focus back first; ask again for up to 10 s.
            let deadline = Date().addingTimeInterval(10)
            var attempts = 0
            var focused = false
            while !focused && Date() < deadline {
                attempts += 1
                run(["focus-window", "\(want)"])
                focused = poll(timeout: 1.5) { self.hasFocus(want) }
                if !focused && attempts == 1 {
                    let f = frames()
                    log("focus: window \(want) has no focus before `\(name)`: Striple focus "
                        + "\(state()?.focusedWindow.map { "\($0.id)" } ?? "none"), test app active \(f?.active ?? false), "
                        + "key \(f?.key.map(String.init) ?? "none"), frontmost \(frontmostApp())")
                }
            }
            if attempts > 1 {
                log("focus: \(focused ? "got" : "did not get") the focus for window \(want) after \(attempts) attempts, frontmost \(frontmostApp())")
            }
            // Without the focus the command would act on another window: do not send it.
            if !focused {
                let why = "window \(want) did not get the focus within 10 s before `\(name)` (frontmost \(frontmostApp()))"
                focusFailures.append(why)
                log("striple \(name): not sent, \(why)")
                return ProcResult(code: -1, out: "", err: why, ms: 0)
            }
        }
        let r = run([name])
        cliCommandMs.append(r.ms)
        log("striple \(name): exit \(r.code) in \(String(format: "%.0f", r.ms)) ms\(r.err.isEmpty ? "" : " " + r.err)")
        return r
    }

    /// The app with the keyboard focus, from AX (read only). For the log when a focus step fails.
    func frontmostApp() -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return "unknown" }
        var pid: pid_t = 0
        AXUIElementGetPid(value as! AXUIElement, &pid)
        return "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") (pid \(pid))"
    }

    /// True when Striple and the system both have `id` focused (test app frontmost, window key).
    func hasFocus(_ id: UInt32) -> Bool {
        StripCheck.hasFocus(id, stripleFocus: state()?.focusedWindow?.id, report: frames())
    }

    /// The test window Striple had focused last; used to give focus back after the user clicked elsewhere.
    var lastTestFocus: UInt32?
    private func currentTestFocus() -> UInt32? {
        if let f = state()?.focusedWindow, f.bundleID == E2EIDs.windowsBundleID { lastTestFocus = f.id }
        return lastTestFocus
    }

    func stopStriple(wait: Double = 5) -> Bool {
        guard let p = striple else { return true }
        return Proc.terminate(p, wait: wait)
    }

    // MARK: Waiting

    /// Polls `condition` every 50 ms until it is true or the time is over.
    func poll(timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return condition()
    }

    /// Waits until `check` passes on frames that did not change for 250 ms (the animation is over), see
    /// `SettleTracker`. Returns the failures of the last try; empty when it settled and passed.
    func settle(timeout: Double = 3, _ check: (WindowReport) -> [String]) -> [String] {
        let start = Date()
        var tracker = SettleTracker()
        while Date().timeIntervalSince(start) < timeout {
            if let f = frames(), tracker.observe(f.windows, failures: check(f), now: Date().timeIntervalSince(start)) {
                settleMs.append(Date().timeIntervalSince(start) * 1000)
                return []
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        settleMs.append(Date().timeIntervalSince(start) * 1000)
        settleTimeouts += 1
        return tracker.last
    }

    // MARK: Cleanup

    /// Quits the test app and Striple and deletes the temporary STRIPLE_HOME. Safe to call more than once.
    func cleanup() {
        lifecycle.lock()
        stopping = true
        let windowsApp = self.windowsApp, striple = self.striple
        lifecycle.unlock()
        if let p = windowsApp, p.isRunning {
            _ = send(.quit, timeout: 2)
            if !Proc.terminate(p, wait: 3) { Proc.forceKill(p) }
        }
        if let p = striple, p.isRunning {
            if !Proc.terminate(p, wait: 5) {
                log("Striple did not quit within 5 s after SIGTERM, killing it")
                Proc.forceKill(p)
            }
        }
        let fm = FileManager.default
        let engineLog = home.appendingPathComponent("Logs/engine.log")
        if fm.fileExists(atPath: engineLog.path) {
            try? fm.copyItem(at: engineLog, to: config.outDir.appendingPathComponent("engine.log"))
        }
        if fm.fileExists(atPath: home.path) { try? fm.removeItem(at: home) }
    }
}
