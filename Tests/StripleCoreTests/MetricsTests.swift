import Foundation
import Testing
@testable import StripleCore

/// Shared helpers for the metrics tests. Plain data only: no process, no executable file.
enum MetricsFixtures {
    /// A Gregorian calendar in a fixed time zone, so the tests do not depend on the Mac's settings.
    static func calendar(_ zone: String = "Europe/Amsterdam") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0,
                     in cal: Calendar = calendar()) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    /// A new folder name under the temporary directory. Not created: the store creates it.
    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("striple-metrics-test-\(UUID().uuidString)", isDirectory: true)
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func readDay(_ dir: URL, _ day: String) throws -> DayMetrics {
        try JSONDecoder().decode(DayMetrics.self, from: Data(contentsOf: dir.appendingPathComponent("\(day).json")))
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A clock that the test moves by hand.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    static func store(_ dir: URL, clock: Clock, version: String = "1.0", retention: Int = MetricsStore.defaultRetentionDays,
                      calendar cal: Calendar = calendar()) -> MetricsStore {
        MetricsStore(directory: dir, appVersion: version, retentionDays: retention, calendar: cal, now: { clock.now })
    }
}

@Suite struct HistogramTests {
    @Test func emptyHistogramGivesZero() {
        let h = Histogram()
        #expect(h.counts.count == Histogram.bounds.count + 1)
        #expect(h.count == 0 && h.sum == 0 && h.max == 0)
        #expect(h.percentile(50) == 0)
        #expect(h.percentile(100) == 0)
        #expect(h.mean == 0)
        #expect(h.count(above: 0) == 0)
    }

    @Test func aValueLandsInTheFirstBucketWhoseBoundIsAtLeastTheValue() {
        var h = Histogram()
        h.add(0)
        h.add(0.05)
        h.add(0.06)
        h.add(16.7)
        h.add(5000)
        h.add(5000.01)
        h.add(1e9)
        let overflow = Histogram.bounds.count
        #expect(h.counts[0] == 2)
        #expect(h.counts[1] == 1)
        #expect(h.counts[Histogram.bounds.firstIndex(of: 16.7)!] == 1)
        #expect(h.counts[overflow - 1] == 1)
        #expect(h.counts[overflow] == 2)
        #expect(h.count == 7)
        #expect(h.max == 1e9)
    }

    @Test func nanInfiniteAndNegativeValuesAreIgnored() {
        var h = Histogram()
        for v in [Double.nan, .infinity, -.infinity, -1, -0.001, .greatestFiniteMagnitude] { h.add(v) }
        // greatestFiniteMagnitude is kept; a second one would make the sum infinite and is left out.
        h.add(.greatestFiniteMagnitude)
        #expect(h.count == 1)
        #expect(h.sum.isFinite)
        #expect(h.counts.reduce(0, +) == h.count)
    }

    @Test func percentileIsCappedAtMax() {
        var h = Histogram()
        h.add(0.3)
        #expect(h.percentile(50) == 0.3)
        #expect(h.percentile(99) == 0.3)
    }

    @Test func percentileUsesTheNearestRank() {
        var h = Histogram()
        for _ in 0..<19 { h.add(0.8) }
        h.add(100)
        // Rank of p95 over 20 samples is 19: still in the 1 ms bucket, capped by nothing (max is 100).
        #expect(h.percentile(95) == 1)
        // Rank 20 is the 100 ms sample.
        #expect(h.percentile(96) == 100)
        #expect(h.percentile(0) == 1)
        #expect(h.percentile(-10) == 1)
        #expect(h.percentile(250) == 100)
        #expect(h.percentile(.nan) == 1)
    }

    @Test func overflowBucketReportsMax() {
        var h = Histogram()
        h.add(9000)
        h.add(12000)
        #expect(h.percentile(50) == 12000)
        #expect(h.percentile(100) == 12000)
    }

    @Test func mergeAddsCountsSumAndKeepsTheHigherMax() {
        var a = Histogram(), b = Histogram()
        a.add(1); a.add(3)
        b.add(3); b.add(700); b.add(8000)
        var both = Histogram()
        for v in [1.0, 3, 3, 700, 8000] { both.add(v) }
        a.merge(b)
        #expect(a == both)
        #expect(a.count == 5 && a.sum == 8707 && a.max == 8000)
        var empty = Histogram()
        empty.merge(Histogram())
        #expect(empty == Histogram())
    }

    @Test func meanAndCountAbove() {
        var h = Histogram()
        for v in [1.0, 8, 9, 20, 6000] { h.add(v) }
        #expect(h.mean == 6038.0 / 5)
        #expect(h.count(above: 8) == 3)
        #expect(h.count(above: 5000) == 1)
        #expect(h.count(above: -1) == 5)
    }
}

@Suite struct MetricsDayTests {
    static func sample(_ day: String) -> DayMetrics {
        var d = DayMetrics(day: day)
        d.appVersions = ["1.0"]
        d.activeSeconds = 100
        d.frameWrite.add(2)
        d.commandLatency.add(5)
        d.commandSettle.add(200)
        d.tickInterval.add(16.7)
        d.ticks = 10
        d.slowTicks = 1
        d.cpuSeconds = 0.5
        d.wakeups = 40
        d.peakRSSMB = 50
        d.events = ["swipe": 2]
        d.commands = ["focus-left": ["hotkey": 3]]
        d.columnsPerStrip = ["2": 4]
        var app = AppMetrics()
        app.axWrite.add(1.5)
        app.axErrors = 1
        app.friction = ["user.drag": 1]
        d.apps = ["com.example.a": app]
        return d
    }

    @Test func mergeAddsEveryField() {
        var a = Self.sample("2026-10-12")
        var b = Self.sample("2026-10-13")
        b.appVersions = ["0.9", "1.0"]
        b.peakRSSMB = 80
        b.commands = ["focus-left": ["cli": 1, "hotkey": 1], "wider": ["menu": 2]]
        b.apps["com.example.b"] = AppMetrics()
        a.merge(b)
        #expect(a.day == "2026-10-12")
        #expect(a.appVersions == ["0.9", "1.0"])
        #expect(a.activeSeconds == 200)
        #expect(a.frameWrite.count == 2 && a.commandLatency.count == 2 && a.commandSettle.count == 2 && a.tickInterval.count == 2)
        #expect(a.ticks == 20 && a.slowTicks == 2)
        #expect(a.cpuSeconds == 1 && a.wakeups == 80)
        #expect(a.peakRSSMB == 80)
        #expect(a.events == ["swipe": 4])
        #expect(a.commands == ["focus-left": ["hotkey": 4, "cli": 1], "wider": ["menu": 2]])
        #expect(a.columnsPerStrip == ["2": 8])
        #expect(a.apps["com.example.a"]?.axWrite.count == 2)
        #expect(a.apps["com.example.a"]?.axErrors == 2)
        #expect(a.apps["com.example.a"]?.friction == ["user.drag": 2])
        #expect(a.apps["com.example.b"] == AppMetrics())
    }

    @Test func encodeThenDecodeGivesTheSameDay() throws {
        let d = Self.sample("2026-10-13")
        let back = try JSONDecoder().decode(DayMetrics.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    @Test func missingFieldsGetTheirDefaults() throws {
        let json = #"{"day": "2026-10-13", "events": {"swipe": 2}, "apps": {"com.example.a": {"axErrors": 3}}}"#
        let d = try JSONDecoder().decode(DayMetrics.self, from: Data(json.utf8))
        var expected = DayMetrics(day: "2026-10-13")
        expected.events = ["swipe": 2]
        var app = AppMetrics()
        app.axErrors = 3
        expected.apps = ["com.example.a": app]
        #expect(d == expected)
        let empty = try JSONDecoder().decode(DayMetrics.self, from: Data("{}".utf8))
        #expect(empty == DayMetrics(day: ""))
    }

    @Test func aFieldOfTheWrongTypeGetsItsDefaultAndTheRestLoads() throws {
        let json = #"{"day": "2026-10-13", "ticks": "many", "wakeups": -5, "cpuSeconds": 2, "commands": {"wider": {"cli": 1}}}"#
        let d = try JSONDecoder().decode(DayMetrics.self, from: Data(json.utf8))
        #expect(d.ticks == 0)
        #expect(d.wakeups == 0)
        #expect(d.cpuSeconds == 2)
        #expect(d.commands == ["wider": ["cli": 1]])
    }

    @Test func aBrokenHistogramLoadsEmptyAndABadCountIsFixed() throws {
        let short = #"{"day": "d", "frameWrite": {"counts": [1, 2, 3], "count": 6, "sum": 1, "max": 1}}"#
        #expect(try JSONDecoder().decode(DayMetrics.self, from: Data(short.utf8)).frameWrite == Histogram())
        var counts = Array(repeating: 0, count: Histogram.bounds.count + 1)
        counts[4] = 2
        let wrongCount = #"{"day": "d", "frameWrite": {"counts": \#(counts), "count": 99, "sum": 2, "max": 1}}"#
        var d = try JSONDecoder().decode(DayMetrics.self, from: Data(wrongCount.utf8))
        #expect(d.frameWrite.count == 2)
        // The loaded histogram takes new values without a crash.
        d.frameWrite.add(1)
        #expect(d.frameWrite.count == 3)
    }

    @Test func aNewerSchemaThrows() {
        let json = #"{"schema": 2, "day": "2026-10-13"}"#
        #expect(throws: MetricsError.newerSchema(2)) {
            try JSONDecoder().decode(DayMetrics.self, from: Data(json.utf8))
        }
    }

    @Test func anOlderSchemaLoadsAsTheCurrentOne() throws {
        let d = try JSONDecoder().decode(DayMetrics.self, from: Data(#"{"schema": 0, "day": "2026-10-13", "ticks": 4}"#.utf8))
        #expect(d.schema == DayMetrics.schemaVersion)
        #expect(d.ticks == 4)
    }
}

/// The pure logic, without a clock, a lock or files.
@Suite struct MetricsAccumulatorTests {
    typealias F = MetricsFixtures
    let cal = F.calendar()

    func make(_ now: Date) -> MetricsAccumulator {
        MetricsAccumulator(day: DayMetrics(day: MetricsStore.dayKey(now, calendar: cal)), appVersion: "1.0", calendar: cal, now: now)
    }

    @Test func theFirstChangeReportsTheSavedToUnsavedStep() {
        let t = F.date(2026, 10, 13)
        var a = make(t)
        #expect(!a.needsFlush)
        let first = a.record(.swipe, count: 1, now: t)
        let second = a.record(.swipe, count: 1, now: t)
        let ignored = a.recordFrameWrite(ms: .nan, now: t)
        #expect(first)
        #expect(!second)
        #expect(!ignored)
        #expect(a.current.events["swipe"] == 2)
    }

    @Test func rolloverKeepsEveryOldDayUntilTheFlush() {
        var a = make(F.date(2026, 10, 13, 23, 59, 59))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 13, 23, 59, 59))
        _ = a.record(.swipe, count: 2, now: F.date(2026, 10, 14, 0, 0, 0))
        _ = a.recordColumns(1, now: F.date(2026, 10, 16, 8))
        #expect(a.pending.map(\.day) == ["2026-10-13", "2026-10-14"])
        #expect(a.current.day == "2026-10-16")
        #expect(a.current.appVersions == ["1.0"])
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 16, 9))
        #expect(batch.map(\.day) == ["2026-10-13", "2026-10-14", "2026-10-16"])
        #expect(batch.map { $0.events["swipe"] ?? 0 } == [1, 2, 0])
        #expect(!a.needsFlush)
    }

    @Test func aCleanDayIsNotKeptForTheFlush() {
        var a = make(F.date(2026, 10, 13, 10))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14, 10))
        #expect(a.pending.isEmpty)
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 14, 11))
        #expect(batch.map(\.day) == ["2026-10-14"])
    }

    @Test func theDayNeverMovesBack() {
        var a = make(F.date(2026, 10, 14, 0, 0, 5))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14, 0, 0, 5))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 13, 23, 59, 58))
        #expect(a.current.day == "2026-10-14")
        #expect(a.current.events["swipe"] == 2)
        #expect(a.pending.isEmpty)
    }

    @Test func aFailedWriteIsPutBackWithoutLosingNewerData() {
        var a = make(F.date(2026, 10, 13, 23))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 13, 23))
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 13, 23))
        // While the write runs, a record arrives on the same day: the day in memory is newer than the batch.
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 13, 23, 30))
        let unsavedStep = a.restore(batch)
        #expect(!unsavedStep)
        #expect(a.current.events["swipe"] == 2)
        #expect(a.pending.isEmpty)

        // The day rolls over during a failed write, with no records on the old day: the batch copy goes to pending.
        let batch2 = a.takeFlushBatch(now: F.date(2026, 10, 13, 23, 40))
        _ = a.recordColumns(2, now: F.date(2026, 10, 14, 1))
        #expect(a.pending.isEmpty)
        let unsavedStep2 = a.restore(batch2)
        #expect(!unsavedStep2)
        #expect(a.pending.map(\.day) == ["2026-10-13"])
        #expect(a.pending.first?.events["swipe"] == 2)
    }

    @Test func restoreAfterACleanBatchReportsTheUnsavedStep() {
        var a = make(F.date(2026, 10, 13))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 13))
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 13))
        let unsavedStep = a.restore(batch)
        #expect(unsavedStep)
        #expect(a.needsFlush)
    }

    @Test func protectedDaysAreNeverInABatch() {
        let t = F.date(2026, 10, 13)
        var a = MetricsAccumulator(day: DayMetrics(day: "2026-10-13"), appVersion: "1.0", calendar: cal,
                                   protectedDays: ["2026-10-13"], now: t)
        _ = a.record(.swipe, count: 1, now: t)
        let batch = a.takeFlushBatch(now: t)
        #expect(batch.isEmpty)
        #expect(!a.needsFlush)
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14))
        let next = a.takeFlushBatch(now: F.date(2026, 10, 14))
        #expect(next.map(\.day) == ["2026-10-14"])
    }
}
