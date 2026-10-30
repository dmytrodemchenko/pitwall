import XCTest
@testable import Pitwall

@MainActor
final class AnalyticsTests: XCTestCase {
    private let prices = PriceTable(prices: ["claude-opus": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10)])
    private var cal: Calendar { Calendar.current }

    private func item(_ project: String, daysAgo: Int, input: Int = 1_000_000, model: String = "claude-opus-5-5", now: Date) -> UsageItem {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!.addingTimeInterval(3600)
        return UsageItem(project: project, session: "s", entry: UsageEntry(model: model, timestamp: day, tokens: TokenUsage(input: input)))
    }

    func testCostPerDayStacksTopFiveAndOther() {
        let now = t0
        var items = ["a", "b", "c", "d", "e", "f", "g"].enumerated().map { i, p in
            item(p, daysAgo: 0, input: (10 - i) * 1_000_000, now: now) // a most expensive … g least
        }
        items.append(item("a", daysAgo: 6, now: now))
        items.append(item("a", daysAgo: 7, now: now)) // outside the week
        items.append(item("x", daysAgo: 1, model: "unknown-model", now: now)) // no price: 0, but counted

        let r = CostReport(items: items, prices: prices, now: now)
        XCTAssertEqual(r.days.count, 7)
        XCTAssertEqual(r.days.last, cal.startOfDay(for: now))
        XCTAssertEqual(r.series, ["a", "b", "c", "d", "e", CostReport.other])
        let today = r.bars(on: r.days[6])
        XCTAssertEqual(today.first { $0.series == "a" }?.cost, 50) // 10M input × $5
        XCTAssertEqual(today.first { $0.series == CostReport.other }?.cost, 45) // f (5M) + g (4M) × $5
        XCTAssertEqual(r.bars(on: r.days[0]).map(\.cost), [5])
        XCTAssertEqual(r.projects.first?.project, "a")
        XCTAssertEqual(r.projects.first?.cost, 55)
        XCTAssertEqual(r.projects.first?.tokens, 11_000_000)
        XCTAssertEqual(r.projects.map(\.cost), r.projects.map(\.cost).sorted(by: >))
        XCTAssertEqual(r.projects.count, 8)
    }

    func testImportDeduplicatesAndKeepsThirtyDays() async throws {
        let root = tempDir()
        let dir = root.appending(path: "-p-proj")
        try FileManager.default.createDirectory(at: dir.appending(path: "s1/subagents"), withIntermediateDirectories: true)
        let now = Date()
        func line(_ id: String, _ date: Date, input: Int) -> String {
            let ts = ISO8601DateFormatter().string(from: date)
            return #"{"timestamp":"\#(ts)","cwd":"/p/proj","sessionId":"s1","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":0}}}"# + "\n"
        }
        let main = dir.appending(path: "s1.jsonl")
        append(line("m1", now, input: 100) + line("m1", now, input: 100) // the same message on two lines
               + line("old", now.addingTimeInterval(-31 * 86400), input: 7) + #"{"type":"user"}"# + "\n", to: main)
        // Claude moved into a subfolder: still the same project.
        append(line("sub1", now, input: 5).replacingOccurrences(of: "/p/proj", with: "/p/proj/lib"),
               to: dir.appending(path: "s1/subagents/agent-1.jsonl"))

        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true))
        let suite = "test-\(UUID())"
        await store.importTranscripts(root: root, defaults: UserDefaults(suiteName: suite)!, now: now)
        var items = await store.items(since: .distantPast)
        XCTAssertEqual(items.map(\.entry.tokens.input).sorted(), [5, 100])
        XCTAssertEqual(Set(items.map(\.project)), ["proj"])
        XCTAssertNotNil(UserDefaults(suiteName: suite)!.object(forKey: AnalyticsStore.importedKey))

        // Live: only the new lines.
        append(line("m2", now, input: 1), to: main)
        await store.ingest(transcript: main.path)
        items = await store.items(since: .distantPast)
        XCTAssertEqual(items.map(\.entry.tokens.input).sorted(), [1, 5, 100])
    }

    func testRetentionDropsRowsOlderThanThirtyDays() async throws {
        let dir = tempDir(), now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let transcript = dir.appending(path: "s1.jsonl")
        append(#"{"timestamp":"\#(ts)","cwd":"/p","sessionId":"s1","message":{"id":"m1","model":"x","usage":{"input_tokens":1}}}"# + "\n", to: transcript)
        let log = dir.appending(path: "events.jsonl")
        append(#"{"timestamp":"\#(ts)","session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Agent","subagent_type":"planner"}"# + "\n"
               + #"{"timestamp":"\#(ts)","session_id":"s1","hook_event_name":"SubagentStop","subagent_type":"planner"}"# + "\n", to: log)
        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true))
        await store.ingest(transcript: transcript.path)
        await store.ingestEvents(url: log)

        await store.commit(now: now + 29 * 86400) // still within 30 days
        var (items, runs) = (await store.items(since: .distantPast), await store.gateRuns(since: .distantPast))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(runs.count, 1)
        await store.commit(now: now + 31 * 86400)
        (items, runs) = (await store.items(since: .distantPast), await store.gateRuns(since: .distantPast))
        XCTAssertEqual(items.count, 0)
        XCTAssertEqual(runs.count, 0)
    }

    struct SaveFailed: LocalizedError { var errorDescription: String? { "the disk is full" } }

    @MainActor
    func testFailingSaveIsShown() async throws {
        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true)) { _ in throw SaveFailed() }
        let analytics = Analytics(store: store, prices: PriceTable(prices: [:]))
        let transcript = tempDir().appending(path: "s1.jsonl")
        append(#"{"timestamp":"2026-10-30T08:00:00Z","sessionId":"s1","message":{"id":"m1","model":"x","usage":{"input_tokens":1}}}"# + "\n", to: transcript)
        analytics.ingest(transcript: transcript.path)
        let shown = expectation(for: NSPredicate { _, _ in analytics.saveError == "the disk is full" }, evaluatedWith: nil)
        await fulfillment(of: [shown], timeout: 5)
    }

    // MARK: Cache hit ratio

    private func use(_ at: Date, input: Int = 0, read: Int = 0, write: Int = 0, output: Int = 0) -> UsageEntry {
        UsageEntry(model: "m", timestamp: at, tokens: TokenUsage(input: input, output: output, cacheRead: read,
                                                                 cacheWrite5m: write / 2, cacheWrite1h: write - write / 2))
    }

    func testCacheRatioFormula() throws {
        // read / (read + both cache writes + input); output doesn't count.
        let r = try XCTUnwrap(CacheRatio.of(TokenUsage(input: 10, output: 999, cacheRead: 60, cacheWrite5m: 20, cacheWrite1h: 10)))
        XCTAssertEqual(r, 0.6, accuracy: 1e-9)
        XCTAssertNil(CacheRatio.of(TokenUsage(output: 5)))
    }

    func testLowRatioNeedsTenMinutes() {
        let now = t0
        // A young session writing its cache: not warned yet.
        XCTAssertFalse(CacheRatio.isLow([use(now - 300, write: 100)], now: now, percent: 50))
        // Old enough, last 10 minutes mostly writes: warned.
        var e = [use(now - 1200, read: 1000), use(now - 300, read: 10, write: 90)]
        XCTAssertTrue(CacheRatio.isLow(e, now: now, percent: 50))
        XCTAssertEqual(CacheRatio.recent(e, now: now)!, 0.1, accuracy: 1e-9) // the old good turn is outside the window
        // Recovered.
        e.append(use(now - 60, read: 900))
        XCTAssertFalse(CacheRatio.isLow(e, now: now, percent: 50))
        XCTAssertTrue(CacheRatio.isLow(e, now: now, percent: 95)) // threshold from Settings
        // Nothing in the last 10 minutes: nothing to warn about.
        XCTAssertFalse(CacheRatio.isLow([use(now - 1200, write: 100)], now: now, percent: 50))
    }

    func testCacheReportPerDay() throws {
        let now = cal.startOfDay(for: t0).addingTimeInterval(12 * 3600)
        let r = CacheReport(entries: [use(now - 3600, input: 50, read: 50), use(now - 2 * 86400, read: 3, write: 1),
                                      use(now - 8 * 86400, read: 1)], now: now)
        XCTAssertEqual(r.points.count, 2) // the 8-day-old one is outside; empty days are skipped
        XCTAssertEqual(try XCTUnwrap(r.today), 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.points.first!.ratio, 0.75, accuracy: 1e-9)
        XCTAssertNil(CacheReport(entries: [use(now - 86400, read: 1)], now: now).today)
    }
}
