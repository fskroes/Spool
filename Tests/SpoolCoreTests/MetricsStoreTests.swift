import Foundation
import Testing
@testable import SpoolCore

@Suite struct MetricsStoreTests {
    typealias F = MetricsFixtures
    let cal = F.calendar()

    // MARK: Names and day keys

    @Test func metricNamesGroupFocusWindowOnly() {
        #expect(MetricsStore.metricName(for: .focusWindow(1234)) == "focus-window")
        #expect(MetricsStore.metricName(for: .focusIndex(3)) == "focus-index-3")
        #expect(MetricsStore.metricName(for: .moveToIndex(9)) == "move-to-index-9")
        for command in Command.bindable { #expect(MetricsStore.metricName(for: command) == command.name) }
    }

    @Test func dayKeyIsZeroPaddedLocalAndNotLocalized() {
        #expect(MetricsStore.dayKey(F.date(2026, 1, 5, 9), calendar: cal) == "2026-01-05")
        // 23:30 UTC is already the next day in Amsterdam.
        let late = F.date(2026, 10, 13, 23, 30, in: F.calendar("UTC"))
        #expect(MetricsStore.dayKey(late, calendar: F.calendar("UTC")) == "2026-10-13")
        #expect(MetricsStore.dayKey(late, calendar: cal) == "2026-10-14")
        // Another calendar and locale still give Gregorian ASCII digits.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = cal.timeZone
        buddhist.locale = Locale(identifier: "th_TH")
        #expect(MetricsStore.dayKey(F.date(2026, 10, 13), calendar: buddhist) == "2026-10-13")
        var arabic = cal
        arabic.locale = Locale(identifier: "ar_EG")
        #expect(MetricsStore.dayKey(F.date(2026, 10, 13), calendar: arabic) == "2026-10-13")
    }

    @Test func indexNamesComeFromTablesAndOtherNumbersStillWork() {
        #expect(MetricsStore.focusIndexNames == (1...9).map { "focus-index-\($0)" })
        #expect(MetricsStore.moveToIndexNames == (1...9).map { "move-to-index-\($0)" })
        for n in 1...9 {
            #expect(MetricsStore.metricName(for: .focusIndex(n)) == Command.focusIndex(n).name)
            #expect(MetricsStore.metricName(for: .moveToIndex(n)) == Command.moveToIndex(n).name)
        }
        #expect(MetricsStore.metricName(for: .focusIndex(0)) == "focus-index-0")
        #expect(MetricsStore.metricName(for: .focusIndex(12)) == "focus-index-12")
        #expect(MetricsStore.metricName(for: .moveToIndex(-1)) == "move-to-index--1")
    }

    // MARK: Thread safety and onFirstChange

    @Test func eightThreadsLoseNoCount() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 12))
        let store = F.store(dir, clock: clock)
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        let perThread = 5_000
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for i in 0..<perThread {
                store.record(command: thread % 2 == 0 ? .focusLeft : .focusWindow(UInt32(i)), source: .hotkey)
                store.record(.swipe)
                store.record(.userDrag, bundleID: "com.example.app\(thread % 3)")
                store.recordAXWrite(bundleID: "com.example.ax", ms: 1, failed: i % 2 == 0)
                store.recordFrameWrite(ms: 2)
                store.recordCommandLatency(ms: 3)
                store.recordCommandSettle(ms: 4)
                store.recordTick(intervalMs: i % 10 == 0 ? 40 : 16, periodMs: 16.7)
                store.recordColumns(i % 12 + 1)
                store.recordActive(seconds: 0.25)
                store.recordCost(cpuSeconds: 0.5, wakeups: 1, rssMB: Double(thread))
            }
        }
        let total = 8 * perThread
        let d = store.snapshot()
        #expect(calls.value == 1)
        #expect(d.commands["focus-left"]?["hotkey"] == total / 2)
        #expect(d.commands["focus-window"]?["hotkey"] == total / 2)
        #expect(d.events["swipe"] == total)
        #expect(d.apps.values.reduce(0) { $0 + ($1.friction["user.drag"] ?? 0) } == total)
        #expect(d.apps["com.example.ax"]?.axWrite.count == total)
        #expect(d.apps["com.example.ax"]?.axErrors == total / 2)
        #expect(d.frameWrite.count == total && d.commandLatency.count == total && d.commandSettle.count == total)
        #expect(d.ticks == total && d.tickInterval.count == total)
        #expect(d.slowTicks == total / 10)
        #expect(d.columnsPerStrip.values.reduce(0, +) == total)
        #expect(d.activeSeconds == Double(total) * 0.25)
        #expect(d.cpuSeconds == Double(total) * 0.5)
        #expect(d.wakeups == total)
        #expect(d.peakRSSMB == 7)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13") == d)
    }

    @Test func onFirstChangeRunsOncePerSavedToUnsavedStep() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        #expect(!store.hasUnsavedChanges)
        store.record(.swipe)
        store.record(.fling)
        store.recordFrameWrite(ms: 1)
        #expect(calls.value == 1)
        #expect(store.hasUnsavedChanges)
        try store.flush()
        #expect(!store.hasUnsavedChanges)
        try store.flush()
        #expect(calls.value == 1)
        store.record(command: .wider, source: .menu)
        store.record(command: .wider, source: .menu)
        #expect(calls.value == 2)
    }

    @Test func onFirstChangeRunsOutsideTheLock() {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let seen = F.Counter()
        // The lock is not recursive: these calls would hang if the callback ran under it.
        store.onFirstChange = { [unowned store] in
            if store.hasUnsavedChanges, store.snapshot().events["swipe"] == 1 { seen.increment() }
            store.record(.fling)
        }
        store.record(.swipe)
        #expect(seen.value == 1)
        #expect(store.snapshot().events["fling"] == 1)
    }

    @Test func settingTheCallbackWithUnsavedChangesCallsItAtOnce() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 12))
        F.store(dir, clock: clock).markRunning()
        // The app calls markRunning() before the engine sets the callback.
        let store = F.store(dir, clock: clock)
        #expect(store.markRunning())
        let calls = F.Counter()
        // The callback reads the store: this would hang if the setter called it under the lock.
        store.onFirstChange = { [unowned store] in
            if store.hasUnsavedChanges { calls.increment() }
        }
        #expect(calls.value == 1)
        store.record(.swipe)
        #expect(calls.value == 1)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["unclean.exit"] == 1)
        // Saved: setting it again does not call it.
        store.onFirstChange = { calls.increment() }
        #expect(calls.value == 1)
        // Disabled: a flush is not useful, so it is not called.
        store.record(.swipe)
        #expect(calls.value == 2)
        store.isEnabled = false
        store.onFirstChange = { calls.increment() }
        #expect(calls.value == 2)
        store.onFirstChange = nil
        store.isEnabled = true
        #expect(calls.value == 2)
    }

    @Test func settingTheCallbackAgainDoesNotCallItTwiceForOneChange() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.record(.swipe)
        #expect(calls.value == 1)
        // The owner sets the callback again (for example a new engine): the flush is already asked for.
        store.onFirstChange = { calls.increment() }
        store.onFirstChange = { calls.increment() }
        #expect(calls.value == 1)
        try store.flush()
        store.record(.swipe)
        #expect(calls.value == 2)
    }

    @Test func aCallbackThatSetsItselfAgainDoesNotRecurse() {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        final class Box: @unchecked Sendable { var callback: (@Sendable () -> Void)? }
        let box = Box()
        let calls = F.Counter()
        box.callback = { [unowned store] in
            calls.increment()
            // The limit only stops a broken store from running until the stack overflows.
            if calls.value < 5 { store.onFirstChange = box.callback }
        }
        store.onFirstChange = box.callback
        store.record(.swipe)
        #expect(calls.value == 1)
    }

    @Test func aRecordBeforeAnyCallbackCallsTheFirstCallbackOnce() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        store.record(.swipe)
        store.onFirstChange = nil
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.onFirstChange = { calls.increment() }
        store.record(.fling)
        #expect(calls.value == 1)
    }

    @Test func turningOffOrClearingTheCallbackAsksAgainForTheSameChanges() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.record(.swipe)
        #expect(calls.value == 1)
        // The owner turns the store off and cancels its flush timer: turning on must ask again.
        store.isEnabled = false
        store.isEnabled = true
        #expect(calls.value == 2)
        // The owner clears the callback (and its timer), then sets a new one: it is called for the same changes.
        store.onFirstChange = nil
        store.onFirstChange = { calls.increment() }
        #expect(calls.value == 3)
        // Every other path stays once only.
        store.onFirstChange = { calls.increment() }
        store.record(.fling)
        store.isEnabled = true
        #expect(calls.value == 3)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events == ["swipe": 1, "fling": 1])
    }

    @Test func aFailedWriteAsksForExactlyOneMoreFlush() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try Data("x".utf8).write(to: dir)
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.record(.swipe)
        #expect(throws: (any Error).self) { try store.flush() }
        #expect(calls.value == 2)
        store.onFirstChange = { calls.increment() }
        store.record(.fling)
        store.isEnabled = true
        #expect(calls.value == 2)
        // A flush that finds the store off uses up the request: turning on again asks once more.
        store.isEnabled = false
        #expect(throws: Never.self) { try store.flush() }
        store.isEnabled = true
        store.isEnabled = true
        #expect(calls.value == 3)
    }

    @Test func recordingFromManyThreadsDoesNoFileWork() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        #expect(store.isEnabled)
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for i in 0..<500 {
                store.record(command: .focusIndex(i % 9 + 1), source: .hotkey)
                store.record(.swipe)
                store.record(.userDrag, bundleID: "com.example.\(thread)")
                store.recordAXWrite(bundleID: "com.example.ax", ms: 1, failed: false)
                store.recordFrameWrite(ms: 2)
                store.recordTick(intervalMs: 16, periodMs: 16.7)
                store.recordColumns(i % 12)
                store.recordActive(seconds: 1)
                store.recordCost(cpuSeconds: 0.1, wakeups: 1, rssMB: 10)
                store.noteFocusMove(i % 2 == 0 ? .focusLeft : .focusRight, bundleID: "com.example.b")
                store.noteWidthChange(bundleID: "com.example.w", windowCreatedAt: F.date(2026, 10, 13, 12))
            }
        }
        #expect(store.hasUnsavedChanges)
        // Not even the folder exists before the first flush.
        #expect(!F.exists(dir))
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 4_000)
    }

    @Test func aStoreLoadsHugeCountsAndKeepsRecording() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let max = Int.max
        let counts = (0...Histogram.bounds.count).map { $0 == 5 ? String(max) : "0" }.joined(separator: ", ")
        let json = """
        {"day": "2026-10-13", "ticks": \(max), "slowTicks": \(max), "wakeups": \(max), "events": {"swipe": \(max)},
         "commands": {"wider": {"menu": \(max)}}, "columnsPerStrip": {"1": \(max)},
         "frameWrite": {"counts": [\(counts)], "sum": 1, "max": 1},
         "apps": {"com.example.a": {"axErrors": \(max), "friction": {"user.drag": \(max)}}}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("2026-10-13.json"))
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        store.record(.swipe, count: 5)
        store.record(command: .wider, source: .menu)
        store.recordTick(intervalMs: 100, periodMs: 16.7)
        store.recordColumns(1)
        store.record(.userDrag, bundleID: "com.example.a")
        store.recordAXWrite(bundleID: "com.example.a", ms: 1, failed: true)
        store.recordCost(cpuSeconds: 0, wakeups: 5, rssMB: 0)
        store.recordFrameWrite(ms: 1)
        let d = store.snapshot()
        #expect(d.events["swipe"] == max && d.commands["wider"]?["menu"] == max)
        #expect(d.ticks == max && d.slowTicks == max && d.wakeups == max && d.columnsPerStrip["1"] == max)
        #expect(d.apps["com.example.a"]?.axErrors == max && d.apps["com.example.a"]?.friction["user.drag"] == max)
        #expect(d.frameWrite.count == max)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13") == d)
    }

    @Test func recordsThatChangeNothingKeepTheStoreSaved() {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.recordFrameWrite(ms: .nan)
        store.recordCommandLatency(ms: -1)
        store.recordCommandSettle(ms: .infinity)
        store.recordTick(intervalMs: .nan, periodMs: 16.7)
        store.recordColumns(0)
        store.recordColumns(-3)
        store.record(.swipe, count: 0)
        store.recordActive(seconds: -5)
        store.recordCost(cpuSeconds: .nan, wakeups: -1, rssMB: .nan)
        store.recordAXWrite(bundleID: "com.example.a", ms: .nan, failed: false)
        store.noteWidthChange(bundleID: "com.example.a", windowCreatedAt: F.date(2026, 10, 13, 11))
        #expect(calls.value == 0)
        #expect(!store.hasUnsavedChanges)
    }

    // MARK: Record details

    @Test func recordDetails() {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        for n in [1, 9, 10, 25, 0, -3] { store.recordColumns(n) }
        store.recordTick(intervalMs: 16, periodMs: 20)
        store.recordTick(intervalMs: 30, periodMs: 20)
        store.recordTick(intervalMs: 30.01, periodMs: 20)
        store.recordTick(intervalMs: 90, periodMs: 0)
        store.recordCost(cpuSeconds: 0.25, wakeups: 3, rssMB: 40)
        store.recordCost(cpuSeconds: 0.25, wakeups: 2, rssMB: 30)
        store.recordAXWrite(bundleID: "com.example.a", ms: 2, failed: true)
        store.recordAXWrite(bundleID: "com.example.a", ms: 1, failed: false)
        store.record(.observerRepair, count: 3)
        let d = store.snapshot()
        #expect(d.columnsPerStrip == ["1": 1, "9": 1, "10+": 2])
        #expect(d.ticks == 4 && d.slowTicks == 1)
        #expect(d.cpuSeconds == 0.5 && d.wakeups == 5 && d.peakRSSMB == 40)
        #expect(d.apps["com.example.a"]?.axWrite.count == 2)
        #expect(d.apps["com.example.a"]?.axErrors == 1)
        #expect(d.events["observer.repair"] == 3)
        #expect(d.appVersions == ["1.0"])
    }

    @Test func focusBounceNeedsAnOppositeMoveWithinTheWindow() {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 12))
        let store = F.store(dir, clock: clock)
        func move(_ c: Command, _ id: String? = "com.example.a", after seconds: Double = 0.2) {
            clock.now = clock.now.addingTimeInterval(seconds)
            store.noteFocusMove(c, bundleID: id)
        }
        func bounces(_ id: String = "com.example.a") -> Int { store.snapshot().apps[id]?.friction["focus.bounce"] ?? 0 }

        move(.focusLeft); move(.focusRight)
        #expect(bounces() == 1)
        move(.focusLeft, after: 1.5)
        #expect(bounces() == 1)
        move(.focusUp); move(.focusDown); move(.focusUp)
        #expect(bounces() == 3)
        move(.focusLeft); move(.focusLeft)
        #expect(bounces() == 3)
        // Another command clears the previous move.
        move(.focusRight, after: 2); move(.focusFirst); move(.focusLeft)
        #expect(bounces() == 3)
        move(.focusRight, after: 2); move(.focusWindow(4)); move(.focusLeft)
        #expect(bounces() == 3)
        // A nil bundle ID records nothing but is remembered.
        move(.focusRight, nil, after: 2); move(.focusLeft, nil)
        #expect(store.snapshot().apps.count == 1)
        move(.focusRight, "com.example.b")
        #expect(bounces("com.example.b") == 1)
        // Exactly at the window still counts.
        move(.focusLeft, "com.example.b", after: MetricsStore.bounceWindow)
        #expect(bounces("com.example.b") == 2)
    }

    @Test func earlyResizeCountsOnlyYoungWindows() {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let now = F.date(2026, 10, 13, 12)
        let store = F.store(dir, clock: F.Clock(now))
        for age in [0.0, 5, 9.9, 10, 11, -3] {
            store.noteWidthChange(bundleID: "com.example.a", windowCreatedAt: now.addingTimeInterval(-age))
        }
        #expect(store.snapshot().apps["com.example.a"]?.friction == ["early.resize": 3])
    }

    // MARK: Flush

    @Test func flushCreatesTheFolderAndWritesSortedKeys() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let nested = dir.appendingPathComponent("a/b", isDirectory: true)
        let store = F.store(nested, clock: F.Clock(F.date(2026, 10, 13, 12)))
        store.record(command: .wider, source: .cli)
        store.record(command: .wider, source: .hotkey)
        store.record(.userDrag, bundleID: "com.example.z")
        store.record(.appCorrection, bundleID: "com.example.a")
        try store.flush()
        let data = try Data(contentsOf: nested.appendingPathComponent("2026-10-13.json"))
        #expect(try JSONDecoder().decode(DayMetrics.self, from: data) == store.snapshot())
        let text = String(decoding: data, as: UTF8.self)
        func at(_ s: String) -> String.Index { text.range(of: "\"\(s)\"")!.lowerBound }
        #expect(at("activeSeconds") < at("appVersions"))
        #expect(at("apps") < at("commands"))
        #expect(at("com.example.a") < at("com.example.z"))
        #expect(at("cli") < at("hotkey"))
        #expect(at("day") < at("schema"))
        // Only the day file is there: the atomic write leaves no temporary file behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path) == ["2026-10-13.json"])
    }

    @Test func flushWritesNothingWhenClean() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        try store.flush()
        #expect(!F.exists(dir))
        store.record(.swipe)
        try store.flush()
        let file = dir.appendingPathComponent("2026-10-13.json")
        // Remove the file: a second flush without a change must not write it again.
        try FileManager.default.removeItem(at: file)
        try store.flush()
        #expect(!F.exists(file))
    }

    @Test func disabledStoreRecordsAndWritesNothing() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.isEnabled = false
        #expect(!store.isEnabled)
        store.record(.swipe)
        store.record(command: .wider, source: .cli)
        store.noteFocusMove(.focusLeft, bundleID: "com.example.a")
        store.noteFocusMove(.focusRight, bundleID: "com.example.a")
        #expect(store.snapshot() == DayMetrics(day: "2026-10-13").withVersions(["1.0"]))
        #expect(!store.markRunning())
        try store.flush()
        #expect(!F.exists(dir))
        #expect(calls.value == 0)
    }

    @Test func turningOffKeepsUnsavedDataAndTurningOnAsksForAFlush() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.record(.swipe)
        store.isEnabled = false
        try store.flush()
        #expect(!F.exists(dir))
        store.isEnabled = true
        #expect(calls.value == 2)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 1)
        store.isEnabled = true
        #expect(calls.value == 2)
    }

    @Test func aFailedFlushKeepsTheDataAndAsksAgain() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        // A plain file where the folder should be: creating the folder fails.
        try Data("x".utf8).write(to: dir)
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.record(.swipe)
        #expect(throws: (any Error).self) { try store.flush() }
        #expect(store.hasUnsavedChanges)
        #expect(calls.value == 2)
        store.record(.swipe)
        #expect(calls.value == 2)
        try FileManager.default.removeItem(at: dir)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 2)
        #expect(!store.hasUnsavedChanges)
    }

    @Test func flushesAndRecordsFromManyThreadsKeepEveryCount() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let perThread = 2_000
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for i in 0..<perThread {
                store.record(.swipe)
                if thread < 2, i % 100 == 0 { try? store.flush() }
            }
        }
        try store.flush()
        #expect(!store.hasUnsavedChanges)
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 8 * perThread)
    }

    @Test func twoConcurrentFlushesWriteEveryCountOnce() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        let failures = F.Counter()
        for _ in 0..<20 {
            for _ in 0..<50 { store.record(.swipe) }
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                do { try store.flush() } catch { failures.increment() }
            }
            #expect(!store.hasUnsavedChanges)
        }
        #expect(failures.value == 0)
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 1000)
    }

    // MARK: Day rollover

    @Test func aRecordAfterLocalMidnightGoesToTheNewDayAndTheOldDayIsStillWritten() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 23, 59, 30))
        let store = F.store(dir, clock: clock)
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.record(command: .focusLeft, source: .hotkey)
        store.record(command: .focusLeft, source: .hotkey)
        clock.now = F.date(2026, 10, 14, 0, 0, 10)
        store.record(command: .focusLeft, source: .hotkey)
        #expect(calls.value == 1)
        #expect(store.snapshot().day == "2026-10-14")
        #expect(store.snapshot().commands["focus-left"]?["hotkey"] == 1)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").commands["focus-left"]?["hotkey"] == 2)
        #expect(try F.readDay(dir, "2026-10-14").commands["focus-left"]?["hotkey"] == 1)
        // Nothing is counted twice when the store flushes again.
        store.record(command: .focusLeft, source: .hotkey)
        try store.flush()
        let loaded = MetricsStore.load(directory: dir, days: 7, calendar: cal, now: clock.now)
        let report = MetricsReport.make(days: loaded.days)
        #expect(report.total.commands["focus-left"]?["hotkey"] == 4)
    }

    @Test func midnightUsesTheCalendarTimeZoneNotUTC() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let tokyo = F.calendar("Asia/Tokyo")
        let clock = F.Clock(F.date(2026, 10, 13, 23, 0, in: tokyo))
        let store = F.store(dir, clock: clock, calendar: tokyo)
        store.record(.swipe)
        clock.now = F.date(2026, 10, 14, 0, 30, in: tokyo) // still 2026-10-13 in UTC
        store.record(.swipe)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 1)
        #expect(try F.readDay(dir, "2026-10-14").events["swipe"] == 1)
    }

    @Test func flushAfterMidnightWritesTheOldDayWithoutARecord() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 23, 59))
        let store = F.store(dir, clock: clock)
        store.record(.swipe)
        clock.now = F.date(2026, 10, 14, 0, 1)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 1)
        #expect(!F.exists(dir.appendingPathComponent("2026-10-14.json")))
        #expect(store.snapshot().day == "2026-10-14")
        #expect(!store.hasUnsavedChanges)
    }

    @Test func severalDaysWithoutAFlushAreAllWritten() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 22))
        let store = F.store(dir, clock: clock)
        for day in 13...16 {
            clock.now = F.date(2026, 10, day, 22)
            store.record(.swipe, count: day)
        }
        try store.flush()
        for day in 13...16 { #expect(try F.readDay(dir, "2026-10-\(day)").events["swipe"] == day) }
    }

    @Test func theClockGoingBackOverMidnightAddsToTheWrittenDay() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 23, 59, 50))
        let store = F.store(dir, clock: clock)
        store.record(.swipe)
        clock.now = F.date(2026, 10, 14, 0, 0, 5)
        store.record(.swipe)
        try store.flush()
        clock.now = F.date(2026, 10, 13, 23, 59, 58)
        store.record(.swipe)
        #expect(store.snapshot().day == "2026-10-13")
        try store.flush()
        // The file of the 13th was written before: the new record is added to it, it does not replace it.
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 2)
        #expect(try F.readDay(dir, "2026-10-14").events["swipe"] == 1)
        // The day in memory has the file data now, so a second flush counts nothing twice.
        store.record(.swipe)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 3)
    }

    @Test func aClockAWeekAheadIsCorrectedWithoutARestart() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 9))
        let store = F.store(dir, clock: clock)
        store.record(.swipe, count: 2)
        try store.flush()
        // The clock jumps a week ahead, then NTP sets it back to the real time.
        clock.now = F.date(2026, 10, 20, 9)
        store.record(.fling)
        clock.now = F.date(2026, 10, 13, 9, 5)
        store.record(.swipe)
        #expect(store.snapshot().day == "2026-10-13")
        // Until its first write, the restarted day has only the new record; the write adds the file.
        #expect(store.snapshot().events["swipe"] == 1)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-13").events["swipe"] == 3)
        #expect(store.snapshot().events["swipe"] == 3)
        #expect(try F.readDay(dir, "2026-10-20").events["fling"] == 1)
        // A forward jump to a day whose file this run never read adds to that file.
        clock.now = F.date(2026, 10, 20, 10)
        store.record(.fling)
        #expect(store.snapshot().events["fling"] == 1)
        try store.flush()
        #expect(try F.readDay(dir, "2026-10-20").events["fling"] == 2)
        #expect(store.snapshot().events["fling"] == 2)
    }

    @Test func aJumpToADayWithANewerSchemaFileUsesTheSidecar() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2026-10-12.json")
        let newer = Data(#"{"schema": 3, "day": "2026-10-12"}"#.utf8)
        try newer.write(to: file)
        let clock = F.Clock(F.date(2026, 10, 13, 9))
        let store = F.store(dir, clock: clock)
        clock.now = F.date(2026, 10, 12, 9)
        store.record(.swipe)
        try store.flush()
        #expect(try Data(contentsOf: file) == newer)
        let sidecar = dir.appendingPathComponent("2026-10-12.local.json")
        #expect(try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: sidecar)).events["swipe"] == 1)
        store.record(.swipe)
        try store.flush()
        #expect(try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: sidecar)).events["swipe"] == 2)
    }

    // MARK: Loading at init

    @Test func initContinuesTodaysFile() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 9))
        let first = F.store(dir, clock: clock, version: "1.0")
        first.record(.swipe, count: 2)
        try first.flush()
        clock.now = F.date(2026, 10, 13, 18)
        let second = F.store(dir, clock: clock, version: "1.1")
        #expect(second.snapshot().events["swipe"] == 2)
        #expect(!second.hasUnsavedChanges)
        second.record(.swipe)
        try second.flush()
        let day = try F.readDay(dir, "2026-10-13")
        #expect(day.events["swipe"] == 3)
        #expect(day.appVersions == ["1.0", "1.1"])
    }

    @Test func aNewerSchemaFileOfTodayIsNeverOverwrittenAndTheRecordsGoToTheSidecar() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2026-10-13.json")
        let sidecar = dir.appendingPathComponent("2026-10-13.local.json")
        let newer = Data(#"{"schema": 3, "day": "2026-10-13", "newField": [1, 2, 3]}"#.utf8)
        try newer.write(to: file)
        let clock = F.Clock(F.date(2026, 10, 13, 12))
        let store = F.store(dir, clock: clock)
        let calls = F.Counter()
        store.onFirstChange = { calls.increment() }
        store.record(.swipe)
        #expect(store.snapshot().events["swipe"] == 1)
        try store.flush()
        #expect(try Data(contentsOf: file) == newer)
        #expect(!store.hasUnsavedChanges)
        let saved = try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: sidecar))
        #expect(saved.schema == DayMetrics.schemaVersion && saved.events["swipe"] == 1)
        // Saved, so the next flush (the engine flushes every 60 s) does not ask again.
        try store.flush()
        #expect(calls.value == 1)

        // A restart continues the sidecar, and still never touches the newer file.
        let again = F.store(dir, clock: clock)
        #expect(again.snapshot().events["swipe"] == 1)
        again.record(.swipe)
        try again.flush()
        #expect(try Data(contentsOf: file) == newer)
        #expect(try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: sidecar)).events["swipe"] == 2)

        // The report reads the sidecar and names the newer file as skipped.
        let loaded = MetricsStore.load(directory: dir, days: 1, calendar: cal, now: clock.now)
        #expect(loaded.days.map(\.day) == ["2026-10-13"])
        #expect(loaded.days.first?.events["swipe"] == 2)
        #expect(loaded.skipped == ["2026-10-13.json"])

        // The next day is saved as usual.
        clock.now = F.date(2026, 10, 14, 8)
        again.record(.swipe)
        try again.flush()
        #expect(try Data(contentsOf: file) == newer)
        #expect(try F.readDay(dir, "2026-10-14").events["swipe"] == 1)
        #expect(!F.exists(dir.appendingPathComponent("2026-10-14.local.json")))
    }

    @Test func anUnreadableFileOfTodayIsNeverOverwrittenAndTheRecordsGoToTheSidecar() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2026-10-13.json")
        try Data("not json".utf8).write(to: file)
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)))
        store.record(.swipe)
        try store.flush()
        #expect(!store.hasUnsavedChanges)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
        let saved = try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: dir.appendingPathComponent("2026-10-13.local.json")))
        #expect(saved.events["swipe"] == 1)
    }

    @Test func loadAddsTheSidecarToTheDayFile() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ json: String) throws { try Data(json.utf8).write(to: dir.appendingPathComponent(name)) }
        try write("2026-10-12.json", #"{"ticks": 3, "appVersions": ["2.0"], "events": {"swipe": 1}}"#)
        try write("2026-10-12.local.json", #"{"ticks": 4, "appVersions": ["1.0"], "events": {"swipe": 2}}"#)
        try write("2026-10-13.local.json", #"{"ticks": 5}"#)
        try write("2026-10-11.local.json", "{broken")
        let r = MetricsStore.load(directory: dir, days: 7, calendar: cal, now: F.date(2026, 10, 13, 9))
        #expect(r.days.map(\.day) == ["2026-10-12", "2026-10-13"])
        #expect(r.days.map(\.ticks) == [7, 5])
        #expect(r.days.first?.events["swipe"] == 3)
        #expect(r.days.first?.appVersions == ["1.0", "2.0"])
        #expect(r.skipped == ["2026-10-11.local.json"])
    }

    // MARK: Prune and load

    @Test func pruneDeletesOnlyDayFilesOlderThanTheRetention() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let fm = FileManager.default
        let today = F.date(2026, 10, 13, 12)
        func key(_ back: Int) -> String { MetricsStore.dayKey(cal.date(byAdding: .day, value: -back, to: today)!, calendar: cal) }
        try fm.createDirectory(at: dir.appendingPathComponent("marks/\(key(400))T10-00-00"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("\(key(300)).json"), withIntermediateDirectories: true)
        // Every day of the retention has a file, so the old files are not among the newest 90 days on disk.
        let old = ["\(key(90)).json", "\(key(91)).json", "\(key(365)).json"]
        let kept = (0...89).map { "\(key($0)).json" } + ["notes.txt", "running",
                    "\(key(200)).json.bak", "\(key(200)).JSON", "2026-1-01.json", "abcd-ef-gh.json"]
        for name in old + kept { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("marks/\(key(400)).json"))

        let store = F.store(dir, clock: F.Clock(today), retention: 90)
        store.prune()
        let left = Set(try fm.contentsOfDirectory(atPath: dir.path))
        #expect(left == Set(kept + ["marks", "\(key(300)).json"]))
        #expect(F.exists(dir.appendingPathComponent("marks/\(key(400)).json")))
        #expect(F.exists(dir.appendingPathComponent("marks/\(key(400))T10-00-00")))
    }

    @Test func pruneKeepsExactlyTheRetentionAndEveryDecoy() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let fm = FileManager.default
        let today = F.date(2026, 10, 13, 12)
        func key(_ back: Int) -> String { MetricsStore.dayKey(cal.date(byAdding: .day, value: -back, to: today)!, calendar: cal) }
        try fm.createDirectory(at: dir.appendingPathComponent("marks"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("marks/2020-01-01.json"))
        let decoys = ["running", "notes.json", "2026-01-01.json.bak"]
        let days = (0...6).map { "\(key($0)).json" } + ["\(key(1)).local.json", "\(key(5)).local.json"]
        for name in decoys + days { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }

        F.store(dir, clock: F.Clock(today), retention: 3).prune()
        let left = Set(try fm.contentsOfDirectory(atPath: dir.path))
        let keptDays = ["\(key(0)).json", "\(key(1)).json", "\(key(2)).json", "\(key(1)).local.json"]
        #expect(left == Set(decoys + keptDays + ["marks"]))
        #expect(F.exists(dir.appendingPathComponent("marks/2020-01-01.json")))
    }

    @Test func aWrongClockThatCrossesMidnightKeepsTheRealFiles() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let realToday = F.date(2026, 10, 13, 9)
        let real = (0..<74).map { "\(MetricsStore.dayKey(cal.date(byAdding: .day, value: -$0, to: realToday)!, calendar: cal)).json" }
        #expect(real.contains("2026-08-01.json"))
        for name in real { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        func left() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) }

        // The clock jumps months ahead and the app runs past the wrong midnight: two future days are written,
        // and each flush prunes.
        let clock = F.Clock(F.date(2027, 6, 1, 9))
        let store = F.store(dir, clock: clock, retention: 90)
        store.record(.swipe)
        try store.flush()
        clock.now = F.date(2027, 6, 2, 9)
        store.record(.swipe)
        try store.flush()
        store.prune()
        #expect(try left() == Set(real + ["2027-06-01.json", "2027-06-02.json"]))
        // Back at the real time, nothing is lost either.
        clock.now = realToday
        store.prune()
        #expect(try left() == Set(real + ["2027-06-01.json", "2027-06-02.json"]))
    }

    @Test func aFutureFileDoesNotPushOutADayInsideTheRetention() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["2026-10-10.json", "2026-10-11.json", "2026-10-12.json", "2026-10-13.json", "2027-06-01.json"]
        for name in names { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        // 2026-10-11 is not one of the 3 newest days on disk, but it is inside the 3 days of the clock: it stays.
        F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)), retention: 3).prune()
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == Set(names.dropFirst()))
    }

    @Test func sparseUseKeepsTheLastRetentionDaysOfUse() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let today = F.date(2026, 10, 13, 12)
        func key(_ back: Int) -> String { MetricsStore.dayKey(cal.date(byAdding: .day, value: -back, to: today)!, calendar: cal) }
        // One run every 4 days for 400 days: 100 files, never two days in a row.
        let all = stride(from: 0, to: 400, by: 4).map { "\(key($0)).json" }
        for name in all { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("\(key(396)).local.json"))

        F.store(dir, clock: F.Clock(today), retention: 90).prune()
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == Set(all.prefix(90)))
        #expect(left.count == 90)
    }

    @Test func flushPrunesAfterAWrite() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("2026-10-01.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("2026-10-11.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("2026-10-12.json"))
        let store = F.store(dir, clock: F.Clock(F.date(2026, 10, 13, 12)), retention: 3)
        try store.flush()
        #expect(F.exists(dir.appendingPathComponent("2026-10-01.json")))
        store.record(.swipe)
        try store.flush()
        #expect(!F.exists(dir.appendingPathComponent("2026-10-01.json")))
        #expect(F.exists(dir.appendingPathComponent("2026-10-13.json")))
    }

    @Test func loadReadsTheLastDaysOldestFirstAndNamesBrokenFiles() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ json: String) throws { try Data(json.utf8).write(to: dir.appendingPathComponent(name)) }
        try write("2026-10-05.json", #"{"day": "2026-10-05", "ticks": 5}"#) // outside 7 days
        try write("2026-10-07.json", #"{"day": "2026-10-07", "ticks": 7}"#)
        try write("2026-10-09.json", "{broken")
        try write("2026-10-10.json", #"{"schema": 9}"#)
        try write("2026-10-11.json", #"{"ticks": 11}"#) // no day field: the file name gives it
        try write("2026-10-13.json", #"{"day": "2026-10-13", "ticks": 13}"#)
        try write("2026-10-14.json", #"{"day": "2026-10-14", "ticks": 14}"#) // after today
        try write("notes.txt", "hello")
        let now = F.date(2026, 10, 13, 8)
        let r = MetricsStore.load(directory: dir, days: 7, calendar: cal, now: now)
        #expect(r.days.map(\.day) == ["2026-10-07", "2026-10-11", "2026-10-13"])
        #expect(r.days.map(\.ticks) == [7, 11, 13])
        #expect(r.skipped == ["2026-10-09.json", "2026-10-10.json"])
        #expect(MetricsStore.load(directory: dir, days: 1, calendar: cal, now: now).days.map(\.day) == ["2026-10-13"])
        #expect(MetricsStore.load(directory: dir, days: 0, calendar: cal, now: now).days.isEmpty)
        #expect(MetricsStore.load(directory: dir, days: Int.max, calendar: cal, now: now).days.count == 4)
        #expect(MetricsStore.load(directory: dir.appendingPathComponent("missing"), days: 7, calendar: cal, now: now).days.isEmpty)
    }

    // MARK: Unclean exit

    @Test func theRunningMarkerFindsAnUncleanExit() throws {
        let dir = F.tempDirectory()
        defer { F.remove(dir) }
        let clock = F.Clock(F.date(2026, 10, 13, 12))
        let marker = dir.appendingPathComponent("running")
        let first = F.store(dir, clock: clock)
        #expect(!first.markRunning())
        #expect(F.exists(marker))
        #expect(first.snapshot().events["unclean.exit"] == nil)
        // The first run crashed: no markCleanExit.
        let second = F.store(dir, clock: clock)
        #expect(second.markRunning())
        #expect(second.snapshot().events["unclean.exit"] == 1)
        try second.flush()
        second.markCleanExit()
        #expect(!F.exists(marker))
        let third = F.store(dir, clock: clock)
        #expect(!third.markRunning())
        #expect(third.snapshot().events["unclean.exit"] == 1)
        third.markCleanExit()
        third.markCleanExit()
    }
}

extension DayMetrics {
    func withVersions(_ v: [String]) -> DayMetrics {
        var d = self
        d.appVersions = v
        return d
    }
}
