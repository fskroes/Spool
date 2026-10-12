import Foundation

/// The result of a finished child process.
struct ProcResult {
    var code: Int32
    var out: String
    var err: String
    /// Wall time from launch to exit, in milliseconds.
    var ms: Double
}

enum Proc {
    /// Runs a program to the end and returns its output. `timeout` stops a program that hangs.
    @discardableResult
    static func run(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: Double = 20) -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let start = Date()
        do { try p.run() } catch {
            return ProcResult(code: -1, out: "", err: "cannot run \(exe): \(error.localizedDescription)", ms: 0)
        }
        // Read both pipes while the program runs, so a large output cannot block it.
        var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        let ms = Date().timeIntervalSince(start) * 1000
        return ProcResult(code: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                          err: String(decoding: errData, as: UTF8.self), ms: ms)
    }

    /// Starts a program in the background. Its output goes to `log`.
    static func start(_ exe: String, _ args: [String], env: [String: String], log: URL) throws -> Process {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Sends SIGTERM and waits up to `wait` seconds for the exit. True when the process ended.
    @discardableResult
    static func terminate(_ p: Process, wait: Double) -> Bool {
        guard p.isRunning else { return true }
        kill(p.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(wait)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !p.isRunning
    }

    /// The start time of a running process ("seconds.microseconds"), or nil when no process has this PID.
    /// With the PID it names one process: the system reuses PIDs, not PID plus start time.
    static func startTime(_ pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return "\(t.tv_sec).\(t.tv_usec)"
    }

    /// The executable of a running process, or nil.
    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// SIGTERM to a process that is not our child, then SIGKILL after `wait` seconds. True when it ended.
    @discardableResult
    static func stopPID(_ pid: Int32, wait: Double) -> Bool {
        let start = startTime(pid)
        guard start != nil else { return true }
        kill(pid, SIGTERM)
        let gone = { startTime(pid) != start }
        let deadline = Date().addingTimeInterval(wait)
        while !gone() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if gone() { return true }
        kill(pid, SIGKILL)
        Thread.sleep(forTimeInterval: 0.5)
        return gone()
    }

    /// Last resort for a process that ignored SIGTERM.
    static func forceKill(_ p: Process) {
        guard p.isRunning else { return }
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
    }
}
