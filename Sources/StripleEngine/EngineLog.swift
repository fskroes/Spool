import Foundation
import os
import StripleCore

/// The engine log: `~/Library/Logs/Striple/engine.log`, rotated at 1 MB (one old file kept).
/// Writes happen on a background queue, so logging never slows a frame.
public final class EngineLog: @unchecked Sendable {
    public static let shared = EngineLog(url: StriplePaths.logFile)

    private let url: URL
    private let queue = DispatchQueue(label: "striple.log", qos: .utility)
    private let os = Logger(subsystem: "com.fskroes.Striple", category: "engine")
    private var handle: FileHandle?
    private let maxBytes: UInt64
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL, maxBytes: UInt64 = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        os.info("\(message, privacy: .public)")
        queue.async { [self] in write(line) }
    }

    /// Waits until queued lines are on disk. For tests and before quit.
    public func flush() { queue.sync { try? handle?.synchronize() } }

    private func write(_ line: String) {
        if handle == nil { open() }
        guard let handle else { return }
        handle.write(Data(line.utf8))
        if (try? handle.offset()) ?? 0 > maxBytes { rotate() }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        open()
    }
}
