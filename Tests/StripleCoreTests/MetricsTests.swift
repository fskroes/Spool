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

@Suite struct MetricsHistogramTests {
    static func json(_ text: String) throws -> Histogram {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode(Histogram.self, from: Data(text.utf8))
    }

    static func counts(_ edit: (inout [Int]) -> Void) -> String {
        var c = Array(repeating: 0, count: Histogram.bounds.count + 1)
        edit(&c)
        return "[" + c.map(String.init).joined(separator: ",") + "]"
    }

    @Test func decodingAHistogramDirectlyIsChecked() throws {
        #expect(try Self.json("{}") == Histogram())
        #expect(try Self.json(#"{"counts":[1,2],"count":3,"sum":1,"max":1}"#) == Histogram())
        let negative = Self.counts { $0[3] = 2; $0[4] = -1 }
        #expect(try Self.json(#"{"counts":\#(negative),"count":1,"sum":1,"max":1}"#) == Histogram())
        let good = Self.counts { $0[3] = 2 }
        let h = try Self.json(#"{"counts":\#(good),"count":99,"sum":"nan","max":"inf"}"#)
        #expect(h.count == 2 && h.sum == 0)
        #expect(h.max == Histogram.bounds[2])
        let wrongType = try Self.json(#"{"counts":"x","sum":-5,"max":-1}"#)
        #expect(wrongType == Histogram())
    }

    @Test func aTooSmallMaxIsRaisedToTheLowestValueOfItsBucket() throws {
        // 5 samples in the 75...100 ms bucket, but max 0: the percentile must not be 0.
        let i100 = Histogram.bounds.firstIndex(of: 100)!
        let h = try Self.json(#"{"counts":\#(Self.counts { $0[i100] = 5 }),"sum":450,"max":0}"#)
        #expect(h.max == 75)
        #expect(h.percentile(50) == 75)
        #expect(h.count(above: 50) == 5)
        let overflow = try Self.json(#"{"counts":\#(Self.counts { $0[1] = 1; $0[Histogram.bounds.count] = 2 }),"sum":1,"max":3}"#)
        #expect(overflow.max == 5000)
        #expect(overflow.percentile(100) == 5000)
        // A max inside the bucket stays.
        let inside = try Self.json(#"{"counts":\#(Self.counts { $0[i100] = 1 }),"sum":80,"max":80}"#)
        #expect(inside.max == 80)
    }

    @Test func decodingAppMetricsSkipsOnlyTheBadFrictionEntry() throws {
        let text = #"{"friction":{"user.drag":3,"user.resize":"bad","focus.bounce":null}}"#
        let app = try JSONDecoder().decode(AppMetrics.self, from: Data(text.utf8))
        #expect(app.friction == ["user.drag": 3])
    }

    @Test func decodingAppMetricsDirectlyIsChecked() throws {
        let text = #"{"axErrors":-3,"friction":{"user.drag":-1,"user.resize":2},"axWrite":{"counts":[1]}}"#
        let app = try JSONDecoder().decode(AppMetrics.self, from: Data(text.utf8))
        #expect(app.axErrors == 0)
        #expect(app.friction == ["user.drag": 0, "user.resize": 2])
        #expect(app.axWrite == Histogram())
        #expect(try JSONDecoder().decode(AppMetrics.self, from: Data("{}".utf8)) == AppMetrics())
        var good = AppMetrics()
        good.axWrite.add(3)
        good.axErrors = 2
        good.friction = ["user.drag": 1]
        #expect(try JSONDecoder().decode(AppMetrics.self, from: JSONEncoder().encode(good)) == good)
    }

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

    @Test func countAboveIsZeroAtOrAboveMax() {
        var h = Histogram()
        h.add(0.3)
        // 0.3 is in the bucket with bound 0.5, which is above 0.4, but no sample is above 0.4.
        #expect(h.count(above: 0.4) == 0)
        #expect(h.count(above: 0.3) == 0)
        #expect(h.count(above: 0.25) == 1)
        #expect(Histogram().count(above: 0) == 0)
    }

    @Test func hugeCountsSaturateInsteadOfTrapping() {
        var counts = Array(repeating: 0, count: Histogram.bounds.count + 1)
        counts[3] = Int.max
        counts[10] = Int.max
        var h = Histogram(checking: counts, sum: 1, max: 9)
        #expect(h.count == Int.max)
        h.merge(h)
        h.add(1)
        #expect(h.count == Int.max)
        #expect(h.counts[3] == Int.max)
        #expect(h.percentile(50) == 0.5)
        #expect(h.percentile(100) <= 9)
        #expect(h.count(above: 0.5) == Int.max)
        var big = Histogram()
        big.add(.greatestFiniteMagnitude)
        big.merge(big)
        #expect(big.sum.isFinite)
        #expect(big.count == 2)
        // A counts array of the wrong length gives an empty histogram.
        #expect(Histogram(checking: [Int.max, 1, 2], sum: 5, max: 1) == Histogram())
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
    @Test func aBadDictionaryEntryIsSkippedAndTheOthersStay() throws {
        let text = """
        {"schema": 1, "day": "2026-10-13",
         "events": {"swipe": 500, "x": "bad", "fling": -2},
         "commands": {"wider": {"hotkey": 4, "menu": "bad"}, "narrower": 7, "focus-left": {"cli": 1}},
         "columnsPerStrip": {"2": 9, "3": [1]},
         "apps": {"com.example.a": {"axErrors": 2, "friction": {"user.drag": 1, "user.resize": {}}},
                  "com.example.bad": 5, "com.example.b": {"axErrors": 1}}}
        """
        let d = try JSONDecoder().decode(DayMetrics.self, from: Data(text.utf8))
        #expect(d.events == ["swipe": 500, "fling": 0])
        #expect(d.commands == ["wider": ["hotkey": 4], "focus-left": ["cli": 1]])
        #expect(d.columnsPerStrip == ["2": 9])
        #expect(Set(d.apps.keys) == ["com.example.a", "com.example.b"])
        #expect(d.apps["com.example.a"]?.axErrors == 2)
        #expect(d.apps["com.example.a"]?.friction == ["user.drag": 1])
        #expect(d.apps["com.example.b"]?.axErrors == 1)
        // Not an object at all: the default.
        let notObjects = try JSONDecoder().decode(DayMetrics.self, from: Data(#"{"day":"2026-10-13","events":[1],"apps":"x"}"#.utf8))
        #expect(notObjects.events.isEmpty && notObjects.apps.isEmpty)
    }

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

    @Test func aDamagedFileWithHugeCountsLoadsMergesAndReportsWithoutATrap() throws {
        let max = Int.max
        let counts = (0...Histogram.bounds.count).map { $0 == 4 ? String(max) : "0" }.joined(separator: ", ")
        let json = """
        {"day": "2026-10-13", "ticks": \(max), "slowTicks": \(max), "wakeups": \(max), "activeSeconds": 1e300,
         "cpuSeconds": 1e300, "events": {"swipe": \(max), "unclean.exit": \(max), "fling": -5},
         "commands": {"wider": {"menu": \(max), "cli": \(max), "url": -1}}, "columnsPerStrip": {"1": \(max), "2": -3},
         "frameWrite": {"counts": [\(counts)], "sum": 1e308, "max": 3},
         "commandLatency": {"counts": [1, 2, 3], "sum": 6, "max": 3},
         "apps": {"com.example.a": {"axErrors": \(max), "friction": {"user.drag": \(max), "user.resize": -2},
                                    "axWrite": {"counts": [\(counts)], "sum": 2, "max": 1}}}}
        """
        let day = try JSONDecoder().decode(DayMetrics.self, from: Data(json.utf8))
        #expect(day.events == ["swipe": max, "unclean.exit": max, "fling": 0])
        #expect(day.commands["wider"] == ["menu": max, "cli": max, "url": 0])
        #expect(day.columnsPerStrip == ["1": max, "2": 0])
        #expect(day.apps["com.example.a"]?.friction == ["user.drag": max, "user.resize": 0])
        #expect(day.frameWrite.count == max)
        #expect(day.commandLatency == Histogram())

        var total = day
        total.merge(day)
        total.merge(day)
        #expect(total.ticks == max && total.slowTicks == max && total.wakeups == max)
        #expect(total.events["swipe"] == max)
        #expect(total.commands["wider"]?["menu"] == max)
        #expect(total.columnsPerStrip["1"] == max)
        #expect(total.apps["com.example.a"]?.axErrors == max)
        #expect(total.apps["com.example.a"]?.friction["user.drag"] == max)
        #expect(total.frameWrite.count == max && total.frameWrite.sum.isFinite)
        #expect(total.activeSeconds.isFinite && total.cpuSeconds.isFinite)

        let report = MetricsReport.make(days: [day, day])
        #expect(report.commands.first?.total == max)
        #expect(report.budgets.first { $0.budget.name == "unclean-exits" }?.pass == false)
        let text = report.renderText()
        #expect(text.contains("unclean-exits") && text.contains("FAIL"))
    }

    @Test func aNewerSchemaThrows() {
        let json = #"{"schema": 3, "day": "2026-10-13"}"#
        #expect(throws: MetricsError.newerSchema(3)) {
            try JSONDecoder().decode(DayMetrics.self, from: Data(json.utf8))
        }
    }

    /// Schema 2 added `frameOwn`. A schema 1 file has none: it loads with an empty one, and the rest stays.
    @Test func aSchema1FileLoadsWithoutFrameOwn() throws {
        var old = DayMetrics(day: "2026-10-13")
        old.frameWrite.add(1.1)
        old.frameWrite.add(1.3)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["schema"] = 1
        object.removeValue(forKey: "frameOwn")
        let d = try JSONDecoder().decode(DayMetrics.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(DayMetrics.schemaVersion == 2)
        #expect(d.schema == 2)
        #expect(d.frameWrite.count == 2)
        #expect(d.frameOwn.count == 0)
    }

    @Test func frameOwnRoundTripsAndMerges() throws {
        var a = DayMetrics(day: "2026-10-13")
        a.frameOwn.add(0.3)
        a.frameOwn.add(0.7)
        let back = try JSONDecoder().decode(DayMetrics.self, from: JSONEncoder().encode(a))
        #expect(back.frameOwn == a.frameOwn)
        var b = DayMetrics(day: "2026-10-13")
        b.frameOwn.add(1.2)
        a.merge(b)
        #expect(a.frameOwn.count == 3)
        #expect(a.frameOwn.max == 1.2)
    }

    /// A frame write with its own part fills both histograms; without one, only the frame write.
    @Test func recordFrameWriteFillsFrameOwn() {
        let t = MetricsFixtures.date(2026, 10, 13)
        let cal = MetricsFixtures.calendar()
        var a = MetricsAccumulator(DayEntry(DayMetrics(day: MetricsStore.dayKey(t, calendar: cal)), includesDisk: true),
                                   appVersion: "1.0", calendar: cal, now: t)
        _ = a.recordFrameWrite(ms: 3, ownMs: 0.4, now: t)
        _ = a.recordFrameWrite(ms: 2, now: t)
        #expect(a.current.frameWrite.count == 2)
        #expect(a.current.frameOwn.count == 1)
        #expect(a.current.frameOwn.sum == 0.4)
        // A NaN own part is ignored, the wall time is still recorded and marks the day changed.
        #expect(a.recordFrameWrite(ms: 1, ownMs: .nan, now: t) || a.needsFlush)
        #expect(a.current.frameOwn.count == 1)
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
        MetricsAccumulator(DayEntry(DayMetrics(day: MetricsStore.dayKey(now, calendar: cal)), includesDisk: true),
                           appVersion: "1.0", calendar: cal, now: now)
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
        #expect(batch.map { $0.metrics.events["swipe"] ?? 0 } == [1, 2, 0])
        #expect(!a.needsFlush)
    }

    @Test func aCleanDayIsNotKeptForTheFlush() {
        var a = make(F.date(2026, 10, 13, 10))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14, 10))
        #expect(a.pending.isEmpty)
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 14, 11))
        #expect(batch.map(\.day) == ["2026-10-14"])
    }

    @Test func theDayFollowsTheClockBackAndForward() {
        var a = make(F.date(2026, 10, 14, 0, 0, 5))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14, 0, 0, 5))
        // The clock goes back over midnight: records go to the older day, the newer day waits in pending.
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 13, 23, 59, 58))
        #expect(a.current.day == "2026-10-13")
        #expect(a.current.events["swipe"] == 1)
        #expect(a.current.appVersions == ["1.0"])
        #expect(!a.entry.includesDisk)
        #expect(a.pending.map(\.day) == ["2026-10-14"])
        // Forward again: the day in pending becomes current again, with its records.
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14, 0, 1))
        #expect(a.current.day == "2026-10-14")
        #expect(a.current.events["swipe"] == 2)
        #expect(a.entry.includesDisk)
        #expect(a.pending.map(\.day) == ["2026-10-13"])
        // A jump of a week forward, then back.
        _ = a.record(.fling, count: 1, now: F.date(2026, 10, 21, 9))
        _ = a.record(.fling, count: 1, now: F.date(2026, 10, 14, 9))
        #expect(a.current.day == "2026-10-14")
        #expect(a.pending.map(\.day) == ["2026-10-13", "2026-10-21"])
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 14, 9))
        #expect(batch.map(\.day) == ["2026-10-13", "2026-10-14", "2026-10-21"])
        #expect(batch.map(\.includesDisk) == [false, true, false])
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
        #expect(a.pending.first?.metrics.events["swipe"] == 2)
    }

    @Test func restoreAfterACleanBatchReportsTheUnsavedStep() {
        var a = make(F.date(2026, 10, 13))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 13))
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 13))
        let unsavedStep = a.restore(batch)
        #expect(unsavedStep)
        #expect(a.needsFlush)
    }

    @Test func aSidecarDayIsStillInTheBatch() {
        let t = F.date(2026, 10, 13)
        var a = MetricsAccumulator(DayEntry(DayMetrics(day: "2026-10-13"), includesDisk: true, sidecar: true),
                                   appVersion: "1.0", calendar: cal, now: t)
        _ = a.record(.swipe, count: 1, now: t)
        let batch = a.takeFlushBatch(now: t)
        #expect(batch.map(\.day) == ["2026-10-13"])
        #expect(batch.first?.sidecar == true)
        #expect(!a.needsFlush)
    }

    @Test func absorbAddsTheDiskDataOnceToTheDaysInMemory() {
        var a = make(F.date(2026, 10, 13))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 20))
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 20))
        #expect(batch.map(\.includesDisk) == [false])
        // A record arrives while the flush reads and writes the file.
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 20, 13))
        var saved = DayMetrics(day: "2026-10-20")
        saved.events = ["swipe": 5]
        saved.appVersions = ["0.9"]
        let disk = DiskDay(day: "2026-10-20", sidecar: true, metrics: saved)
        a.absorb([(batch[0].serial, disk)])
        a.absorb([(batch[0].serial, disk)])
        #expect(a.current.events["swipe"] == 7)
        #expect(a.current.appVersions == ["0.9", "1.0"])
        #expect(a.entry.includesDisk && a.entry.sidecar)
    }

    @Test func aDayStartedAgainDuringAFlushGetsNoStaleDiskDataAndKeepsAFailedBatch() {
        var a = make(F.date(2026, 10, 13, 10))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14, 10))
        let batch = a.takeFlushBatch(now: F.date(2026, 10, 14, 10))
        // During the write the clock leaves the 14th (clean, so dropped) and comes back: a new entry starts.
        _ = a.record(.fling, count: 1, now: F.date(2026, 10, 15, 10))
        _ = a.record(.swipe, count: 1, now: F.date(2026, 10, 14, 11))
        #expect(a.entry.serial != batch[0].serial)
        var saved = DayMetrics(day: "2026-10-14")
        saved.events = ["swipe": 5]
        let disk = DiskDay(day: "2026-10-14", sidecar: false, metrics: saved)
        // The file read was from before the write. The new entry must read the file again, not get this copy.
        a.absorb([(batch[0].serial, disk)])
        #expect(a.current.events["swipe"] == 1)
        #expect(!a.entry.includesDisk)
        // The write failed: the batch (with the file data) is added to the new entry, so nothing is lost.
        var unwritten = batch
        unwritten[0].absorb(disk)
        let step = a.restore(unwritten)
        #expect(!step)
        #expect(a.current.events["swipe"] == 7)
        #expect(a.entry.includesDisk)
        #expect(a.pending.map(\.day) == ["2026-10-15"])
    }
}
