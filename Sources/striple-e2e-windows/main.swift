import AppKit
import StripleE2EKit

// The E2E test window app. Opens N titled, resizable windows ("E2E 1"...) on the main display, writes their
// frames every 100 ms to a JSON file (atomic), and runs commands from a file it polls. See docs/E2E.md.
//
// Usage: striple-e2e-windows --count <n> --report <path> --commands <path>
// It must run from an app bundle with the bundle ID com.fskroes.Striple.e2e-windows (the runner makes one),
// because Striple matches apps by bundle ID.

struct Options {
    var count = 3
    var report = ""
    var commands = ""

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var i = 0
        while i < args.count {
            let a = args[i]
            guard i + 1 < args.count else { return nil }
            switch a {
            case "--count": guard let n = Int(args[i + 1]), n >= 0 else { return nil }; o.count = n
            case "--report": o.report = args[i + 1]
            case "--commands": o.commands = args[i + 1]
            default: return nil
            }
            i += 2
        }
        return o.report.isEmpty || o.commands.isEmpty ? nil : o
    }
}

@MainActor
final class TestWindows: NSObject, NSApplicationDelegate {
    private let options: Options
    private var windows: [NSWindow] = []
    private var opened = 0
    private var seq = 0
    private var commandsDone = 0
    private var timer: Timer?
    /// Encodes and writes the report off the main thread. The main thread answers Striple's AX calls; a file
    /// write there (open, fsync, rename) would delay them and add the test app's own time to Striple's numbers.
    /// Serial, so the reports land in `seq` order.
    private let reportQueue = DispatchQueue(label: "striple-e2e-windows.report", qos: .utility)

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for _ in 0..<options.count { openWindow() }
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        tick()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func openWindow() {
        opened += 1
        let n = opened
        guard let screen = NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        // Staggered, well inside the main display, so the start state is on screen.
        let size = NSSize(width: 520, height: 380)
        let origin = NSPoint(x: v.minX + 80 + CGFloat((n - 1) % 6) * 60, y: v.maxY - 120 - size.height - CGFloat((n - 1) % 6) * 50)
        let w = NSWindow(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "E2E \(n)"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 80, height: 60)
        let label = NSTextField(labelWithString: "Striple E2E test window \(n). It closes when the test ends.")
        label.frame = NSRect(x: 20, y: 20, width: 480, height: 24)
        w.contentView?.addSubview(label)
        windows.append(w)
        w.makeKeyAndOrderFront(nil)
    }

    private func close(title: String) {
        guard let i = windows.firstIndex(where: { $0.title == title }) else { return }
        let w = windows.remove(at: i)
        w.close()
    }

    private func tick() {
        runCommands()
        writeReport()
    }

    private func runCommands() {
        guard let data = FileManager.default.contents(atPath: options.commands),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = WindowCommand.completeLines(text)
        while commandsDone < lines.count {
            let line = lines[commandsDone]
            commandsDone += 1
            switch WindowCommand(line: line) {
            case .open: openWindow()
            case .close(let title): close(title: title)
            case .quit:
                writeReport()
                reportQueue.sync {}
                NSApp.terminate(nil)
            case nil: FileHandle.standardError.write(Data("unknown command: \(line)\n".utf8))
            }
        }
    }

    private func writeReport() {
        guard let primary = NSScreen.screens.first else { return }
        seq += 1
        let list = windows.filter(\.isVisible).map {
            ReportedWindow(title: $0.title, number: $0.windowNumber,
                           frame: Coordinates.topLeft($0.frame, primaryHeight: primary.frame.height))
        }
        let report = WindowReport(pid: getpid(), seq: seq, commandsDone: commandsDone, windows: list,
                                  active: NSApp.isActive, key: NSApp.keyWindow?.windowNumber)
        let path = options.report
        reportQueue.async {
            guard let data = try? JSONEncoder().encode(report) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: striple-e2e-windows --count <n> --report <path> --commands <path>\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = TestWindows(options: options)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
