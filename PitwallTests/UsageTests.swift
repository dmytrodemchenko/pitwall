import XCTest
@testable import Pitwall

func usageLine(id: String, model: String = "claude-opus-5-5", ts: String = "2026-10-30T07:30:23.159Z",
               input: Int = 10, output: Int = 20, read: Int = 100, write5m: Int = 0, write1h: Int = 50) -> String {
    #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)}}}}"# + "\n"
}

final class UsageRecordTests: XCTestCase {
    func testParsesUsageAndCacheTTLSplit() throws {
        let r = try XCTUnwrap(UsageRecord.parse(Data(usageLine(id: "m1", write5m: 7, write1h: 50).utf8)))
        XCTAssertEqual(r.messageID, "m1")
        XCTAssertEqual(r.entry.model, "claude-opus-5-5")
        XCTAssertEqual(r.entry.tokens, TokenUsage(input: 10, output: 20, cacheRead: 100, cacheWrite5m: 7, cacheWrite1h: 50))
    }

    func testCacheWriteWithoutBreakdownCountsAs5m() throws {
        let line = #"{"timestamp":"2026-10-30T07:30:23Z","message":{"id":"m","model":"x","usage":{"input_tokens":1,"cache_creation_input_tokens":40}}}"#
        let r = try XCTUnwrap(UsageRecord.parse(Data(line.utf8)))
        XCTAssertEqual(r.entry.tokens.cacheWrite5m, 40)
        XCTAssertEqual(r.entry.tokens.cacheWrite1h, 0)
    }

    func testLinesWithoutUsageAreSkipped() {
        XCTAssertNil(UsageRecord.parse(Data(#"{"type":"user","timestamp":"2026-10-30T07:30:23Z","message":{"role":"user","content":"hi"}}"#.utf8)))
        XCTAssertNil(UsageRecord.parse(Data("garbage".utf8)))
    }
}

@MainActor
final class UsageStoreTests: XCTestCase {
    let dir = tempDir()
    var transcript: URL { dir.appending(path: "sess.jsonl") }
    lazy var store = UsageStore()

    func testDuplicateMessageLinesCountedOnce() {
        append(usageLine(id: "m1") + usageLine(id: "m1") + usageLine(id: "m2"), to: transcript)
        store.refreshAndWait(session: "s", transcriptPath: transcript.path)
        XCTAssertEqual(store.entries(for: "s").count, 2)
        // Same message again in a later write, plus a new one.
        append(usageLine(id: "m2") + usageLine(id: "m3"), to: transcript)
        store.refreshAndWait(session: "s", transcriptPath: transcript.path)
        XCTAssertEqual(store.entries(for: "s").count, 3)
        XCTAssertEqual(store.entries(for: "s").tokens.input, 30)
    }

    func testIncludesSubagentTranscripts() throws {
        append(usageLine(id: "m1"), to: transcript)
        let subDir = dir.appending(path: "sess/subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        append(usageLine(id: "a1", model: "claude-haiku-5-5"), to: subDir.appending(path: "agent-x.jsonl"))
        try "{}".write(to: subDir.appending(path: "agent-x.meta.json"), atomically: true, encoding: .utf8)
        store.refreshAndWait(session: "s", transcriptPath: transcript.path)
        XCTAssertEqual(store.entries(for: "s").map(\.model).sorted(), ["claude-haiku-5-5", "claude-opus-5-5"])
    }

    /// A day's transcript can be tens of MB: launch must not wait for it, and the main thread
    /// (popover, permission socket) must stay free while it is read.
    func testBigTranscriptIsReadOffTheMainThread() throws {
        try writeBigSession(in: dir)

        let start = Date()
        let monitor = Monitor(dir: dir) { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        let mainIsFree = expectation(description: "main runs while still importing")
        DispatchQueue.main.async { if monitor.usage.entries.isEmpty { mainIsFree.fulfill() } }
        wait(for: [mainIsFree], timeout: 1)
        let imported = expectation(for: NSPredicate { _, _ in monitor.usage.entries["s1"]?.count == 1 }, evaluatedWith: nil)
        wait(for: [imported], timeout: 60)
    }

    func testForgetDropsTheSession() {
        append(usageLine(id: "m1"), to: transcript)
        store.refreshAndWait(session: "s", transcriptPath: transcript.path)
        store.forget("s")
        XCTAssertTrue(store.entries(for: "s").isEmpty)
        XCTAssertNil(store.contexts["s"])
        store.refreshAndWait(session: "s", transcriptPath: transcript.path) // a new reader starts over
        XCTAssertEqual(store.entries(for: "s").count, 1)
    }

    func testTodayFiltersByDate() {
        append(usageLine(id: "old", ts: "2026-10-29T12:00:00Z") + usageLine(id: "new", ts: "2026-10-30T12:00:00Z"), to: transcript)
        store.refreshAndWait(session: "s", transcriptPath: transcript.path)
        let noon = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!
        XCTAssertEqual(store.today(now: noon).count, 1)
    }
}

final class PricingTests: XCTestCase {
    let table = PriceTable(prices: [
        "claude-opus-5": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10),
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8),
    ])

    func testLongestPrefixWins() {
        XCTAssertEqual(table.price(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(table.price(for: "claude-opus-5-5[1m]")?.input, 4)
        XCTAssertEqual(table.price(for: "claude-opus-5")?.input, 5)
        XCTAssertNil(table.price(for: "gpt-5"))
    }

    func testCostMath() {
        let t = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        let e = UsageEntry(model: "claude-opus-5-5", timestamp: t0, tokens: t)
        XCTAssertEqual(table.cost(of: [e, e])!, 2 * (4 + 20 + 0.2 + 5 + 8), accuracy: 1e-9)
    }

    func testUnknownModelMakesCostUnknown() {
        let used = UsageEntry(model: "mystery", timestamp: t0, tokens: TokenUsage(input: 1))
        let empty = UsageEntry(model: "<synthetic>", timestamp: t0, tokens: TokenUsage())
        XCTAssertNil(table.cost(of: [used]))
        XCTAssertEqual(table.cost(of: [empty]), 0) // zero-token entries don't need a price
    }

    func testBundledDefaultIsValidAndCopiedOnFirstLaunch() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "prices", withExtension: "json"))
        let user = tempDir().appending(path: "prices.json")
        let table = PriceTable.load(userFile: user, defaultFile: bundled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.path))
        XCTAssertEqual(table.price(for: "claude-opus-5-5")?.output, 20)
        XCTAssertEqual(table.price(for: "claude-sonnet-4-6")?.input, 3)
    }

    func testInvalidUserFileFallsBackToDefault() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "prices", withExtension: "json"))
        let user = tempDir().appending(path: "prices.json")
        try "not json".write(to: user, atomically: true, encoding: .utf8)
        XCTAssertNotNil(PriceTable.load(userFile: user, defaultFile: bundled).price(for: "claude-haiku-5-5"))
    }
}

@MainActor
final class MonitorTests: XCTestCase {
    func testAlerts() {
        XCTAssertEqual(Monitor.alert(for: event("Notification"), project: "p"), "p needs your input")
        XCTAssertEqual(Monitor.alert(for: event("SubagentStop", agent: "verifier", verdict: "fail"), project: "p"), "p: verifier failed")
        XCTAssertNil(Monitor.alert(for: event("SubagentStop", agent: "verifier", verdict: "pass"), project: "p"))
        XCTAssertNil(Monitor.alert(for: event("PreToolUse", tool: "Bash"), project: "p"))
    }

    func testBacklogDoesNotAlertButLiveEventsDo() {
        let dir = tempDir()
        let log = dir.appending(path: "events.jsonl")
        append(jsonLine("Notification", session: "old"), to: log)
        var alerts: [String] = []
        let got = expectation(description: "live alert")
        let monitor = Monitor(dir: dir) { alerts.append($0); got.fulfill() }
        XCTAssertEqual(monitor.store.sessions.count, 1)
        XCTAssertTrue(alerts.isEmpty)

        append(jsonLine("Notification", session: "new"), to: log)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(alerts, ["p needs your input"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "prices.json").path))
        for file in ["prices.json", "context.json"] { // created owner-only
            let mode = try? FileManager.default.attributesOfItem(atPath: dir.appending(path: file).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, file)
        }
    }
}
