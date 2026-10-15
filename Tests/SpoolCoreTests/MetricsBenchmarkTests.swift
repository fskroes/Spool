import Foundation
import Testing
@testable import SpoolCore

/// The cost of one record call. It measures wall-clock time, so it runs only with SPOOL_BENCH=1, not as a gate test:
/// SPOOL_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter 'SpoolCoreTests\.MetricsBenchmarkTests/'
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SPOOL_BENCH"] == "1"))
struct MetricsBenchmarkTests {
    @Test func recordCallUnderOneMicrosecond() {
        let dir = MetricsFixtures.tempDirectory()
        defer { MetricsFixtures.remove(dir) }
        // The real clock and calendar, as in the app.
        let store = MetricsStore(directory: dir, appVersion: "bench")
        let commands: [Command] = [.focusLeft, .focusRight, .wider, .focusWindow(7), .focusIndex(3), .toggleFullWidth]
        let apps = ["com.apple.Safari", "com.apple.Terminal", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap"]
        // Warm up: the dictionaries reach their final size, so the loop measures the steady state.
        for i in 0..<1_000 {
            store.record(command: commands[i % commands.count], source: .hotkey)
            store.recordAXWrite(bundleID: apps[i % apps.count], ms: 1, failed: false)
            store.record(.userDrag, bundleID: apps[i % apps.count])
            store.recordColumns(i % 12 + 1)
        }
        let calls = 1_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<calls {
            switch i & 7 {
            case 0: store.record(command: commands[i % commands.count], source: .hotkey)
            case 1: store.recordFrameWrite(ms: Double(i & 15) * 0.5)
            case 2: store.recordAXWrite(bundleID: apps[i & 3], ms: Double(i & 7) * 0.3, failed: i & 255 == 2)
            case 3: store.recordTick(intervalMs: 16 + Double(i & 3), periodMs: 16.7)
            case 4: store.recordCommandLatency(ms: Double(i & 31))
            case 5: store.record(.swipe)
            case 6: store.noteFocusMove(i & 8 == 0 ? .focusLeft : .focusRight, bundleID: apps[i & 3])
            default: store.recordColumns(i & 15)
            }
        }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(calls)
        let d = store.snapshot()
        print("Metrics record, mixed calls, \(calls) calls: \(String(format: "%.0f", ns)) ns per call (frames \(d.frameWrite.count))")
        // The budget is for the shipped (release) build. Debug builds are several times slower.
        #if DEBUG
        #expect(ns < 10_000)
        #else
        #expect(ns < 1_000)
        #endif
    }
}
