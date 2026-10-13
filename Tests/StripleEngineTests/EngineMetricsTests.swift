import Foundation
import Testing
@testable import StripleCore
@testable import StripleEngine

// The engine side of the local metrics (F24). Pure: no AX, no window, no process. Files only in a temp folder.

@Suite struct EngineMetricsHelperTests {
    @Test func floatFriction() {
        #expect(Engine.floatFriction(state: .tiled, userFloating: false, offDisplay: false) == .floatTiled)
        // Floated by a rule or the smart check: tiling it is friction.
        #expect(Engine.floatFriction(state: .floating, userFloating: false, offDisplay: false) == .unfloatAuto)
        // The user floated it, or it floats because its display is off: no friction.
        #expect(Engine.floatFriction(state: .floating, userFloating: true, offDisplay: false) == nil)
        #expect(Engine.floatFriction(state: .floating, userFloating: false, offDisplay: true) == nil)
        for state: Engine.ManagedWindow.State in [.minimized, .hidden, .fullscreen] {
            #expect(Engine.floatFriction(state: state, userFloating: false, offDisplay: false) == nil)
        }
    }

    @Test func wallClockOfAMediaTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Engine.wallClock(mediaTime: 95, now: now, mediaNow: 100) == now.addingTimeInterval(-5))
        // A window from before Striple started is never "early".
        #expect(Engine.wallClock(mediaTime: 0, now: now, mediaNow: 100) == .distantPast)
    }

    @Test func logTextReadsTheRotatedFileFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("engine.log")
        #expect(Engine.logText(log) == "")
        try Data("old 1\nold 2\n".utf8).write(to: log.appendingPathExtension("1"))
        try Data("new 1\n".utf8).write(to: log)
        #expect(Engine.logText(log) == "old 1\nold 2\nnew 1\n")
        // A long file: only the end, from the first whole line.
        try Data("aaaa\nbbbb\ncccc\n".utf8).write(to: log)
        #expect(Engine.logText(log, maxBytes: 8) == "old 2\ncccc\n")
    }
}

/// Uses `MetricsStore`: needs the Core metrics types.
@Suite struct MetricsSinkTests {
    @Test func recordsWritesOfKnownApps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetricsStore(directory: dir, appVersion: "test")
        let sink = MetricsSink()
        let write = FrameApplier.WriteTiming(pid: 42, axMs: 3, latencyMs: 4)
        sink.record(write: write)
        #expect(store.snapshot().apps.isEmpty)
        sink.set(store)
        sink.record(write: write)
        #expect(store.snapshot().apps.isEmpty, "a pid without a bundle ID is not recorded")
        sink.setBundle("", for: 42)
        sink.record(write: write)
        #expect(store.snapshot().apps.isEmpty)
        sink.setBundle("com.example.app", for: 42)
        sink.record(write: write)
        var failed = write
        failed.failed = true
        sink.record(write: failed)
        let app = try #require(store.snapshot().apps["com.example.app"])
        #expect(app.axWrite.count == 2)
        #expect(app.axErrors == 1)
        sink.forget(pid: 42)
        sink.record(write: write)
        #expect(store.snapshot().apps["com.example.app"]?.axWrite.count == 2)
        sink.setBundle("com.example.app", for: 42)
        sink.set(nil)
        sink.record(write: write)
        #expect(store.snapshot().apps["com.example.app"]?.axWrite.count == 2)
    }

    @Test func recordTickFeedsTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetricsStore(directory: dir, appVersion: "test")
        let recorder = StatsRecorder()
        Engine.recordTick(recorder, metrics: store, commandStart: nil)(2.5)
        Engine.recordTick(recorder, metrics: store, commandStart: 0)(3)
        Engine.recordTick(recorder, metrics: store, commandStart: 0)(nil)
        let day = store.snapshot()
        #expect(day.frameWrite.count == 2)
        #expect(day.commandLatency.count == 1)
        #expect(recorder.snapshot().batches == 2)
    }
}
