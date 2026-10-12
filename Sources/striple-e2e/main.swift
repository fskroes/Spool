import AppKit
import ApplicationServices
import Foundation
import StripleCore
import StripleE2EKit

// Live end-to-end test of Striple. See docs/E2E.md. Run with `make e2e`.
//
// Exit codes: 0 all checks passed, 1 a check failed, 2 the test could not run (another Striple runs, no
// Accessibility permission, the app is missing). On 2 nothing was started; the caller may retry later.

func usage() -> Never {
    print("""
    usage: striple-e2e [--app <Striple.app>] [--out <dir>] [--bundle-dir <dir>] [--windows-binary <path>]
      --app             default: dist/Striple.app
      --out             report folder, default: /tmp/striple/e2e/<timestamp>
      --bundle-dir      where the test app bundle is made, default: .build/e2e
      --windows-binary  the striple-e2e-windows binary, default: next to this binary
    """)
    exit(2)
}

func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data("striple-e2e: \(message)\n".utf8))
    exit(2)
}

func parseConfig() -> RunConfig {
    var args = Array(CommandLine.arguments.dropFirst())
    var values: [String: String] = [:]
    while !args.isEmpty {
        let a = args.removeFirst()
        guard ["--app", "--out", "--bundle-dir", "--windows-binary"].contains(a), !args.isEmpty else { usage() }
        values[a] = args.removeFirst()
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    func path(_ key: String, _ fallback: URL) -> URL {
        values[key].map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL } ?? fallback
    }
    let stamp: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }()
    let me = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: cwd).resolvingSymlinksInPath()
    return RunConfig(app: path("--app", cwd.appendingPathComponent("dist/Striple.app")),
                     windowsBinary: path("--windows-binary", me.deletingLastPathComponent().appendingPathComponent(E2EIDs.windowsExecutable)),
                     bundleDir: path("--bundle-dir", cwd.appendingPathComponent(".build/e2e")),
                     outDir: path("--out", URL(fileURLWithPath: "/tmp/striple/e2e/\(stamp)")))
}

/// A run that crashed (a trap, SIGKILL) leaves its record: its test Striple can still run, and its STRIPLE_HOME
/// is still on disk. Stop and delete only what the record names, and only when its runner is gone.
func reapOrphanedRun() {
    let fm = FileManager.default
    guard let data = fm.contents(atPath: E2ERunRecord.path) else { return }
    guard let r = try? JSONDecoder().decode(E2ERunRecord.self, from: data) else {
        print("striple-e2e: ignoring an unreadable \(E2ERunRecord.path)")
        try? fm.removeItem(atPath: E2ERunRecord.path)
        return
    }
    if r.runnerIsAlive(currentRunnerStart: Proc.startTime(r.runnerPID)) {
        refuse("another E2E run is active (runner pid \(r.runnerPID)). Wait for it, or retry later.")
    }
    if let pid = r.striplePID, r.isOrphan(currentStart: Proc.startTime(pid)),
       Proc.executablePath(pid)?.hasSuffix("/Contents/MacOS/Striple") == true {
        print("striple-e2e: stopping the test Striple of an earlier run that did not end (pid \(pid))")
        if !Proc.stopPID(pid, wait: 5) { refuse("cannot stop the test Striple (pid \(pid)) of an earlier run") }
    }
    if r.homeIsDeletable, fm.fileExists(atPath: r.home) {
        print("striple-e2e: deleting \(r.home) of an earlier run that did not end")
        try? fm.removeItem(atPath: r.home)
    }
    try? fm.removeItem(atPath: E2ERunRecord.path)
}

func writeRunRecord(_ r: E2ERunRecord) {
    let url = URL(fileURLWithPath: E2ERunRecord.path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(r) { try? data.write(to: url, options: .atomic) }
}

/// Checks that make the run safe and meaningful. Any failure: exit 2, nothing started.
func preflight(_ config: RunConfig) {
    let fm = FileManager.default
    reapOrphanedRun()
    let app = config.app
    for p in ["Contents/MacOS/Striple", "Contents/Helpers/striple"] where !fm.isExecutableFile(atPath: app.appendingPathComponent(p).path) {
        refuse("\(app.path)/\(p) not found. Run `make app` first, or pass --app.")
    }
    if !fm.isExecutableFile(atPath: config.windowsBinary.path) {
        refuse("test app binary \(config.windowsBinary.path) not found. Run `swift build --product \(E2EIDs.windowsExecutable)`.")
    }
    if NSScreen.screens.isEmpty { refuse("no display found") }
    if let d = CGSessionCopyCurrentDictionary() as? [String: Any], (d["CGSSessionScreenIsLocked"] as? Bool) == true {
        refuse("the screen is locked. Unlock it and retry.")
    }
    if !AXIsProcessTrusted() {
        refuse("this terminal has no Accessibility permission, so Striple started from it cannot move windows. "
               + "Allow it in System Settings > Privacy & Security > Accessibility and retry.")
    }
    // Two window managers would fight over the windows, and the user's Striple would tile the test windows.
    let pg = Proc.run("/usr/bin/pgrep", ["-x", "Striple"], timeout: 5)
    let pids = pg.out.split(separator: "\n").map(String.init)
    if !pids.isEmpty { refuse("another Striple is running (pid \(pids.joined(separator: ", "))). Quit it, or retry later.") }
    let defaultSocket = StriplePaths.resolve(environment: [:], home: fm.homeDirectoryForCurrentUser).support
        .appendingPathComponent("striple.sock").path
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "STRIPLE_SOCKET")
    let ping = Proc.run(app.appendingPathComponent("Contents/Helpers/striple").path, ["ping", "--socket", defaultSocket], env: env, timeout: 5)
    if ping.code == 0 { refuse("a Striple answers on \(defaultSocket). Quit it, or retry later.") }
    // A test app left over from an aborted run would add windows to the strip.
    for old in NSRunningApplication.runningApplications(withBundleIdentifier: E2EIDs.windowsBundleID) {
        print("striple-e2e: quitting a test app left over from an earlier run (pid \(old.processIdentifier))")
        old.forceTerminate()
    }
}

func otherWindows(excluding: Set<Int32>) -> [WindowSnapshot] {
    // All windows, not only on-screen ones: a window on another Space, or minimized, keeps its bounds, so a Space
    // switch by the user during the run does not hide a move from the compare.
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return SafetyCheck.snapshot(list, excluding: excluding) { pid in
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }
}

func makeTempHome() -> URL {
    var template = Array("/tmp/striple-e2e-XXXXXX".utf8CString)
    guard let p = mkdtemp(&template) else { refuse("cannot make a temporary STRIPLE_HOME: \(String(cString: strerror(errno)))") }
    return URL(fileURLWithPath: String(cString: p), isDirectory: true)
}

let config = parseConfig()
preflight(config)
try? FileManager.default.createDirectory(at: config.outDir, withIntermediateDirectories: true)
let home = makeTempHome()
var runRecord = E2ERunRecord(home: home.path, runnerPID: getpid(), runnerStart: Proc.startTime(getpid()) ?? "?")
writeRunRecord(runRecord)
let harness = Harness(config: config, home: home)
let scenarios = Scenarios(harness: harness)

// Ctrl-C or a kill of the runner: still quit the test app and Striple and delete STRIPLE_HOME.
let cleanupLock = NSLock()
var cleanedUp = false
func cleanupOnce() {
    cleanupLock.lock()
    defer { cleanupLock.unlock() }
    guard !cleanedUp else { return }
    cleanedUp = true
    harness.cleanup()
    try? FileManager.default.removeItem(atPath: E2ERunRecord.path)
}
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler {
        FileHandle.standardError.write(Data("striple-e2e: stopped by signal \(sig), cleaning up\n".utf8))
        cleanupOnce()
        exit(130)
    }
    s.resume()
    signalSources.append(s)
}

let g = scenarios.g
harness.log("out: \(config.outDir.path)")
harness.log("STRIPLE_HOME: \(home.path)")
harness.log("app: \(config.app.path)")
harness.log("display: \(FrameChecks.describe(g.display)), work area \(FrameChecks.describe(g.work)), \(NSScreen.screens.count) display(s)")

var notes: [String] = [
    "App: `\(config.app.path)`. Main display \(FrameChecks.describe(g.display)), work area \(FrameChecks.describe(g.work)), \(NSScreen.screens.count) display(s).",
    "Config: defaults with `onboardingDone: true` (inner gap \(Int(g.gap)), presets \(harness.layout.presetWidths.map { String(format: "%.3f", $0) }.joined(separator: ", ")), default width \(harness.layout.defaultWidth)).",
    "Logs: `run.log`, `striple-stdout.log`, `engine.log`, `windows-app.log` in this folder.",
]

var before: [WindowSnapshot] = []
func setupFailed(_ why: String) {
    scenarios.add(.init(scenario: "Setup", result: .fail, details: why))
}

do {
    let bundle = try harness.makeWindowsBundle()
    before = otherWindows(excluding: [getpid()])
    harness.log("recorded \(before.count) windows of other apps")
    try harness.startWindowsApp(bundle)
    let opened = harness.poll(timeout: 10) { (harness.frames()?.windows.count ?? 0) == config.windowCount }
    if !opened {
        setupFailed("the test app did not show \(config.windowCount) windows within 10 s")
    } else {
        try harness.startStriple()
        if let pid = harness.striple?.processIdentifier {
            runRecord.striplePID = pid
            runRecord.stripleStart = Proc.startTime(pid)
            writeRunRecord(runRecord)
        }
        if !harness.poll(timeout: 15, { harness.ping() }) {
            setupFailed("Striple did not answer on \(harness.socket) within 15 s")
        } else if let s = harness.state(), !s.accessibilityTrusted || !s.running {
            setupFailed("Striple runs but the engine is not running (Accessibility: \(s.accessibilityTrusted ? "granted" : "missing"))")
        } else {
            if scenarios.tiling() {
                scenarios.focus()
                scenarios.move()
                scenarios.widths()
                scenarios.closeAndOpen()
                scenarios.float()
            } else {
                // The strip is in an unknown state: their results would only repeat the tiling failure.
                Scenarios.stripScenarios.forEach { scenarios.skip($0, because: "a. Tiling failed") }
            }
            // Stats before the quit: they live in the Striple process.
            scenarios.performance()
            scenarios.quit()
        }
    }
} catch {
    setupFailed("\(error)")
}

// The safety checks run after Striple quit: the restore at quit moves windows too. Setup failures and a slow
// quit leave Striple running here, so stop it first.
if let p = harness.striple, p.isRunning, !harness.stopStriple(wait: 5) {
    Proc.forceKill(p)
    notes.append("Striple did not quit within 5 s of SIGTERM and was killed before the safety compare.")
}
var exclude: Set<Int32> = [getpid()]
if let p = harness.windowsAppPID { exclude.insert(p) }
if let p = harness.striple?.processIdentifier { exclude.insert(p) }
let after = otherWindows(excluding: exclude)
let safety = SafetyCheck.verdict(before: before.filter { !exclude.contains($0.pid) }, after: after)
scenarios.add(.init(scenario: "Safety: windows of other apps did not move or resize", result: safety.result, details: safety.details))
scenarios.add(.init(scenario: "Safety: Striple managed only test windows",
                    result: harness.foreignManaged.isEmpty ? .pass : .fail,
                    details: harness.foreignManaged.isEmpty
                        ? "every window in every `striple state` had bundle ID \(E2EIDs.windowsBundleID)"
                        : harness.foreignManaged.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")))

cleanupOnce()
notes.append(FileManager.default.fileExists(atPath: home.path)
    ? "Cleanup: could not delete STRIPLE_HOME `\(home.path)`."
    : "Cleanup: test app quit, Striple stopped, STRIPLE_HOME deleted.")

let reportURL = config.outDir.appendingPathComponent("report.md")
let markdown = Report.markdown(title: "Striple E2E \(config.outDir.lastPathComponent)", rows: scenarios.rows, notes: notes)
try? Data(markdown.utf8).write(to: reportURL)
print("\n" + markdown)
print("Report: \(reportURL.path)")
exit(Report.exitCode(scenarios.rows))
