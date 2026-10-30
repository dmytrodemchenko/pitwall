import XCTest
@testable import Pitwall

final class CacheExpiryTests: XCTestCase {
    private let prices = PriceTable(prices: ["claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.2,
                                                                            cacheWrite5m: 5, cacheWrite1h: 8)])

    private func entry(at minute: Double, write5m: Int = 0, write1h: Int = 0) -> UsageEntry {
        UsageEntry(model: "claude-opus-5-5", timestamp: t0 + minute * 60,
                   tokens: TokenUsage(input: 1, cacheRead: 1000, cacheWrite5m: write5m, cacheWrite1h: write1h))
    }

    /// The TTL follows the session's last cache write: 1 h writes keep the cache an hour.
    func testTTLFromTheLastCacheWrite() {
        XCTAssertEqual(CacheExpiry.ttl([]), 300)
        XCTAssertEqual(CacheExpiry.ttl([entry(at: 0, write5m: 10), entry(at: 1)]), 300)
        XCTAssertEqual(CacheExpiry.ttl([entry(at: 0, write5m: 10), entry(at: 1, write1h: 10)]), 3600)
        XCTAssertEqual(CacheExpiry.ttl([entry(at: 1, write5m: 10), entry(at: 0, write1h: 10)]), 300)
    }

    /// After expiry the whole context is written again instead of read: the difference is the extra cost.
    func testExtraCostAndMessage() throws {
        let context = ContextUsage(tokens: 200_000, model: "claude-opus-5-5", at: t0)
        XCTAssertEqual(try XCTUnwrap(CacheExpiry.extraCost(context, ttl: 300, prices: prices)), 0.96, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(CacheExpiry.extraCost(context, ttl: 3600, prices: prices)), 1.56, accuracy: 1e-9)
        XCTAssertNil(CacheExpiry.extraCost(ContextUsage(tokens: 1, model: "gpt", at: t0), ttl: 300, prices: prices))
        XCTAssertEqual(CacheExpiry.message(project: "shop", left: 90, extra: 0.96, estimate: false),
                       "shop: prompt cache expires in 2 min\nA message after that costs $0.96 more")
        XCTAssertEqual(CacheExpiry.message(project: "shop", left: 70, extra: 0.96, estimate: false),
                       "shop: prompt cache expires in 1 min\nA message after that costs $0.96 more", "to the nearest minute")
        XCTAssertEqual(CacheExpiry.message(project: "shop", left: 20, extra: 0.96, estimate: true),
                       "shop: prompt cache expires in 1 min\nA message after that costs ≈ $0.96 more")
    }

    @MainActor
    func testMonitorWarnsOnceForAWaitingSession() throws {
        let dir = tempDir(), transcript = dir.appending(path: "s1.jsonl"), log = dir.appending(path: "events.jsonl")
        let iso = ISO8601DateFormatter(), last = Date() - 4 * 60
        // Monitor reads transcripts only for sessions with events today.
        try XCTSkipUnless(Calendar.current.isDate(last, inSameDayAs: Date() + 10), "the session would start before midnight")
        try (#"{"type":"assistant","timestamp":"\#(iso.string(from: last))","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":199999,"cache_creation_input_tokens":0,"output_tokens":500}}}"# + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        func hook(_ name: String, _ session: String = "s1") -> String {
            #"{"timestamp":"\#(iso.string(from: last))","session_id":"\#(session)","cwd":"/x/shop","hook_event_name":"\#(name)","transcript_path":"\#(transcript.path)"}"# + "\n"
        }
        try (hook("SessionStart") + hook("Stop")).write(to: log, atomically: true, encoding: .utf8)
        var alerts: [String] = []
        let monitor = Monitor(dir: dir) { alerts.append($0) }
        monitor.cacheMinCost = { 0.5 }
        monitor.isEstimate = { false }
        wait(for: [expectation(for: NSPredicate { _, _ in monitor.usage.contexts["s1"] != nil }, evaluatedWith: nil)], timeout: 3)

        monitor.checkCaches(now: last + 2 * 60)
        XCTAssertEqual(alerts, [], "3 min left: too early")
        monitor.checkCaches(now: last + 4 * 60)
        monitor.checkCaches(now: last + 4.5 * 60)
        XCTAssertEqual(alerts, ["shop: prompt cache expires in 1 min\nA message after that costs $0.96 more"])
        monitor.checkCaches(now: last + 6 * 60)
        XCTAssertEqual(alerts.count, 1, "already expired")

        alerts = []
        let cheap = Monitor(dir: dir) { alerts.append($0) }
        cheap.cacheMinCost = { 2 }
        wait(for: [expectation(for: NSPredicate { _, _ in cheap.usage.contexts["s1"] != nil }, evaluatedWith: nil)], timeout: 3)
        cheap.checkCaches(now: last + 4 * 60)
        XCTAssertEqual(alerts, [], "below the minimum cost")
    }
}
