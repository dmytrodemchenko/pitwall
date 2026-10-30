import XCTest
@testable import Pitwall

final class GateTimingTests: XCTestCase {
    private var store: SessionStore!
    override func setUp() { store = SessionStore() }
    private var runs: [String: GateRun] { store.sessions["s1"]?.gateRuns ?? [:] }

    func testGateRunsFromDelegationToSubagentStop() {
        store.apply(event("PreToolUse", tool: "Agent", agent: "architect", at: t0))
        XCTAssertEqual(runs["architect"], GateRun(start: t0, end: nil))
        XCTAssertEqual(runs["architect"]?.duration(now: t0 + 75), 75) // still running: counts up
        store.apply(event("SubagentStop", agent: "architect", at: t0 + 134))
        XCTAssertEqual(runs["architect"]?.duration(now: t0 + 999), 134) // finished: fixed
        store.apply(event("PreToolUse", tool: "Task", agent: "planner", at: t0 + 140))
        store.apply(event("SubagentStop", at: t0 + 200)) // a stop without a type still ends the open gate
        XCTAssertEqual(runs["planner"]?.end, t0 + 200)
    }

    func testParallelAgentsEndSeparately() {
        store.apply(event("PreToolUse", tool: "Agent", agent: "developer", at: t0))
        store.apply(event("PreToolUse", tool: "Agent", agent: "Explore", at: t0 + 10))
        store.apply(event("SubagentStop", agent: "Explore", at: t0 + 20))
        XCTAssertNil(runs["developer"]?.end)
        XCTAssertEqual(runs["Explore"]?.end, t0 + 20)
        store.apply(event("SubagentStop", agent: "developer", at: t0 + 300))
        XCTAssertEqual(runs["developer"]?.end, t0 + 300)
        store.apply(event("SubagentStop", agent: "developer", at: t0 + 900)) // a later stop doesn't move it
        XCTAssertEqual(runs["developer"]?.end, t0 + 300)
        store.apply(event("SubagentStop", agent: "", at: t0 + 950)) // a fork: no type, nothing to end
        XCTAssertEqual(runs["developer"]?.end, t0 + 300)
    }

    /// A foreground agent may send no typed SubagentStop; its handback ends the run.
    func testHandbackEndsTheRun() {
        store.apply(event("PreToolUse", tool: "Agent", agent: "web-fetch", at: t0))
        store.apply(event("PreToolUse", tool: "SubagentHandback", agent: "web-fetch", at: t0 + 50))
        store.apply(event("PostToolUse", tool: "SubagentHandback", agent: "web-fetch", at: t0 + 51))
        store.apply(event("SubagentStop", agent: "", at: t0 + 60))
        XCTAssertEqual(runs["web-fetch"], GateRun(start: t0, end: t0 + 50))
    }

    /// SendMessage resumes an agent without an Agent call: its own tool calls start a new run.
    func testResumedAgentStartsANewRun() {
        store.apply(event("PreToolUse", tool: "Agent", agent: "qa-tester", at: t0))
        store.apply(event("SubagentStop", agent: "qa-tester", at: t0 + 60))
        store.apply(event("PostToolUse", tool: "Agent", agent: "qa-tester", at: t0 + 61)) // after the stop: no reopen
        XCTAssertEqual(runs["qa-tester"]?.end, t0 + 60)
        store.apply(event("PreToolUse", tool: "SendMessage", at: t0 + 100))
        store.apply(event("PreToolUse", tool: "Bash", agent: "qa-tester", at: t0 + 105))
        store.apply(event("PreToolUse", tool: "Read", agent: "qa-tester", at: t0 + 110))
        XCTAssertEqual(runs["qa-tester"], GateRun(start: t0 + 105, end: nil))
    }

    func testRerunStartsOver() {
        store.apply(event("PreToolUse", tool: "Agent", agent: "developer", at: t0))
        store.apply(event("SubagentStop", agent: "developer", at: t0 + 60))
        store.apply(event("PreToolUse", tool: "Agent", agent: "developer", at: t0 + 500))
        XCTAssertEqual(runs["developer"], GateRun(start: t0 + 500, end: nil))
    }

    func testFormat() {
        XCTAssertEqual(GateRun.format(0), "0s")
        XCTAssertEqual(GateRun.format(14.9), "14s")
        XCTAssertEqual(GateRun.format(134), "2m 14s")
        XCTAssertEqual(GateRun.format(600), "10m 0s")
        XCTAssertEqual(GateRun.format(3_780), "1h 3m")
        XCTAssertEqual(GateRun(start: t0, end: nil).duration(now: t0 - 5), 0) // clock skew: never negative
    }
}
