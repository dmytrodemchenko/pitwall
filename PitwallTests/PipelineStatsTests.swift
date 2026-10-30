import XCTest
@testable import Pitwall

final class PipelineStatsTests: XCTestCase {
    private func run(_ gate: String, minutes: Double, endedAgo: TimeInterval = 3600, message: String? = nil,
                     verdict: String? = nil, now: Date = t0) -> GateRunItem {
        let end = now - endedAgo
        return GateRunItem(session: "s", gate: gate, start: end - minutes * 60, end: end, lastMessage: message, verdict: verdict)
    }

    func testAverageMedianAndSlowest() throws {
        let runs = [run("planner", minutes: 1), run("planner", minutes: 2), run("planner", minutes: 9), // odd: median 2
                    run("developer", minutes: 4), run("developer", minutes: 6), // even: median 5
                    run("developer", minutes: 99, endedAgo: 8 * 86400)] // outside the 7 days
        let r = PipelineReport(runs: runs, pattern: Verifier.defaultPattern, now: t0)
        XCTAssertEqual(r.gates.map(\.name), ["planner", "developer"]) // pipeline order, gates without runs left out
        let planner = try XCTUnwrap(r.gates.first)
        XCTAssertEqual(planner.runs, 3)
        XCTAssertEqual(planner.average, 4 * 60, accuracy: 0.001)
        XCTAssertEqual(planner.median, 2 * 60, accuracy: 0.001)
        XCTAssertEqual(r.gates[1].median, 5 * 60, accuracy: 0.001)
        XCTAssertEqual(r.slowest, "planner") // 12 min in total against 10
        XCTAssertNil(r.failureRate)
    }

    func testBuiltInAgentsAreApartAndNeverTheSlowestGate() {
        let runs = [run("general-purpose", minutes: 30), run("code-simplifier:code-simplifier", minutes: 20),
                    run("developer", minutes: 5)]
        let r = PipelineReport(runs: runs, pattern: Verifier.defaultPattern, now: t0)
        XCTAssertEqual(r.gates.filter(\.isPipeline).map(\.name), ["developer"])
        XCTAssertEqual(r.slowest, "developer")
    }

    func testVerifierFailureRateUsesThePattern() {
        let runs = [run("verifier", minutes: 1, message: "3 tests broke.\nVERDICT: FAIL"),
                    run("verifier", minutes: 1, message: "all green. verdict: pass"),
                    run("verifier", minutes: 1, message: "Result: REJECTED"),
                    run("verifier", minutes: 1, verdict: "fail")] // older log line: the hook's verdict
        let standard = PipelineReport(runs: runs, pattern: Verifier.defaultPattern, now: t0)
        XCTAssertEqual(standard.verifierRuns, 4)
        XCTAssertEqual(standard.verifierFailures, 2)
        XCTAssertEqual(standard.failureRate, 0.5)
        let custom = PipelineReport(runs: runs, pattern: "verdict: fail|rejected", now: t0)
        XCTAssertEqual(custom.verifierFailures, 3)
    }

    func testPatternMatching() {
        XCTAssertTrue(Verifier.failed(message: "…\nverdict: fail", pattern: "VERDICT: FAIL")) // any case
        XCTAssertFalse(Verifier.failed(message: "VERDICT: PASS", pattern: "VERDICT: FAIL"))
        // Only the last non-empty line: a report quoting the instructions still passes.
        XCTAssertFalse(Verifier.failed(message: "End with VERDICT: PASS or VERDICT: FAIL.\nVERDICT: PASS\n \n", pattern: "VERDICT: FAIL"))
        XCTAssertTrue(Verifier.failed(message: "Tests broke.\n**VERDICT: FAIL**\n", pattern: "VERDICT: FAIL"))
        XCTAssertTrue(Verifier.failed(message: "status=FAILED (2)", pattern: #"status=fail\w*"#))
        XCTAssertFalse(Verifier.isValid("fail("))
        XCTAssertTrue(Verifier.failed(message: "it said fail( here", pattern: "fail(")) // invalid regex: plain text
        XCTAssertNil(Verifier.failed(message: nil, verdict: nil, pattern: "x"))
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        XCTAssertEqual(Verifier.pattern(defaults), "VERDICT: FAIL")
        defaults.set("  ", forKey: Verifier.patternKey)
        XCTAssertEqual(Verifier.pattern(defaults), "VERDICT: FAIL")
    }

    func testRunsFromEvents() {
        var b = GateRunBuilder()
        var stop = event("SubagentStop", agent: "verifier", at: t0 + 90)
        stop.lastMessage = "VERDICT: FAIL"
        let events = [event("PreToolUse", tool: "Agent", agent: "planner", at: t0),
                      event("SubagentStop", agent: "Explore", at: t0 + 10), // another subagent: planner still open
                      event("SubagentStop", agent: "planner", at: t0 + 30),
                      event("PreToolUse", tool: "Agent", agent: "developer", at: t0 + 40),
                      event("PreToolUse", tool: "Agent", agent: "verifier", at: t0 + 60), // developer never finished
                      event("PreToolUse", tool: "SubagentHandback", agent: "verifier", at: t0 + 85), // waits for the stop
                      stop,
                      event("SubagentStop", agent: "verifier", at: t0 + 99), // nothing open
                      event("PreToolUse", tool: "Agent", agent: "web-fetch", at: t0 + 100),
                      event("PreToolUse", tool: "SubagentHandback", agent: "web-fetch", at: t0 + 120), // no typed stop follows
                      event("SubagentStop", agent: "", at: t0 + 130)]
        let runs = events.compactMap { b.apply($0) }
        XCTAssertEqual(runs.map(\.gate), ["planner", "verifier", "web-fetch"])
        XCTAssertEqual(runs[0].duration, 30)
        XCTAssertEqual(runs[1].duration, 25)
        XCTAssertEqual(runs[1].lastMessage, "VERDICT: FAIL")
        XCTAssertEqual(runs[2].duration, 20)
    }

    func testSessionStoreUsesThePattern() throws {
        let line = #"{"timestamp":"2026-10-30T08:00:00Z","session_id":"s1","cwd":"/p","hook_event_name":"SubagentStop","subagent_type":"verifier","verdict":"pass","last_message":"Result: REJECTED"}"#
        let e = try XCTUnwrap(HookEvent.parse(Data(line.utf8)))
        XCTAssertEqual(e.lastMessage, "Result: REJECTED")
        let store = SessionStore()
        store.verifierPattern = { "rejected" }
        store.apply(event("PreToolUse", tool: "Agent", agent: "verifier"))
        store.apply(e)
        XCTAssertTrue(try XCTUnwrap(store.sessions["s1"]).verifierFailed)
        XCTAssertNil(Monitor.alert(for: e, project: "p")) // with the default pattern, "REJECTED" isn't a failure
    }

    func testStoreKeepsRunsFromTheEventLog() async throws {
        let log = tempDir().appending(path: "events.jsonl")
        func line(_ name: String, _ secs: Int, agent: String, tool: String? = nil) -> String {
            let ts = ISO8601DateFormatter().string(from: Date() - 600 + Double(secs))
            return #"{"timestamp":"\#(ts)","session_id":"s1","cwd":"/p","hook_event_name":"\#(name)","tool_name":\#(tool.map { "\"\($0)\"" } ?? "null"),"subagent_type":"\#(agent)"}"# + "\n"
        }
        append(line("PreToolUse", 0, agent: "architect", tool: "Agent") + line("SubagentStop", 120, agent: "architect"), to: log)
        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true))
        await store.ingestEvents(url: log)
        await store.ingestEvents(url: log) // nothing new: no duplicates
        append(line("PreToolUse", 200, agent: "planner", tool: "Agent") + line("SubagentStop", 260, agent: "planner"), to: log)
        await store.ingestEvents(url: log)
        let runs = await store.gateRuns(since: .distantPast)
        XCTAssertEqual(runs.map(\.gate).sorted(), ["architect", "planner"])
        XCTAssertEqual(runs.first { $0.gate == "architect" }?.duration, 120)
    }
}
