import XCTest
@testable import Pitwall

final class LoopDetectorTests: XCTestCase {
    private func call(_ tool: String, _ detail: String, agent: String? = nil, at minute: Double) -> HookEvent {
        var e = event("PreToolUse", tool: tool, agent: agent, at: t0 + minute * 60)
        e.toolDetail = detail
        return e
    }

    func testSameCallFiveTimesWithoutAnEditIsALoop() throws {
        var d = LoopDetector()
        for i in 0..<4 { XCTAssertNil(d.observe(call("Bash", "npm test", agent: "developer", at: Double(i)), verifierFailed: nil)) }
        let loop = try XCTUnwrap(d.observe(call("Bash", "npm test", agent: "developer", at: 4), verifierFailed: nil))
        XCTAssertEqual(loop.count, 5)
        XCTAssertEqual(loop.agent, "developer")
        XCTAssertEqual(loop.since, t0)
        XCTAssertEqual(loop.message(project: "shop", cost: 3.2, now: t0 + 600),
                       "shop: developer is looping, $3.20 in 10 min\nSame call 5 times: Running npm test")
        // Reported once: the count starts over.
        XCTAssertNil(d.observe(call("Bash", "npm test", agent: "developer", at: 5), verifierFailed: nil))
    }

    func testAnEditInBetweenIsProgress() {
        var d = LoopDetector()
        for i in 0..<8 {
            let e = i % 2 == 0 ? call("Bash", "npm test", at: Double(i)) : call("Edit", "/p/a.swift", at: Double(i))
            XCTAssertNil(d.observe(e, verifierFailed: nil))
        }
    }

    func testCallsOutsideTheWindowDontCount() {
        var d = LoopDetector()
        for i in 0..<10 { XCTAssertNil(d.observe(call("Read", "/p/a.swift", at: Double(i) * 3), verifierFailed: nil)) }
    }

    func testTwelveEditsOfOneFile() throws {
        var d = LoopDetector()
        for i in 0..<11 {
            XCTAssertNil(d.observe(call(i % 2 == 0 ? "Edit" : "Write", "/p/Cart.swift", at: Double(i) / 2), verifierFailed: nil))
            XCTAssertNil(d.observe(call("Edit", "/p/other\(i).swift", at: Double(i) / 2), verifierFailed: nil))
        }
        let loop = try XCTUnwrap(d.observe(call("Edit", "/p/Cart.swift", at: 6), verifierFailed: nil))
        XCTAssertEqual(loop.kind, .edits(file: "Cart.swift"))
        XCTAssertEqual(loop.message(project: "shop", cost: nil, now: t0 + 360), "shop: Agent is looping, 6 min\n12 edits to Cart.swift")
    }

    func testThreeVerifierFailsInARow() throws {
        var d = LoopDetector()
        let stop = { (m: Double) in event("SubagentStop", agent: "verifier", at: t0 + m * 60) }
        XCTAssertNil(d.observe(stop(0), verifierFailed: true))
        XCTAssertNil(d.observe(stop(5), verifierFailed: false)) // a pass breaks the streak
        XCTAssertNil(d.observe(stop(10), verifierFailed: true))
        XCTAssertNil(d.observe(stop(20), verifierFailed: true))
        XCTAssertNil(d.observe(event("PreToolUse", tool: "Agent", agent: "developer", at: t0 + 1500), verifierFailed: nil))
        let loop = try XCTUnwrap(d.observe(stop(30), verifierFailed: true))
        XCTAssertEqual(loop.kind, .verifierFails)
        XCTAssertEqual(loop.since, t0 + 600)
    }

    @MainActor
    func testMonitorAlertsLiveLoopsOnly() throws {
        let dir = tempDir(), log = dir.appending(path: "events.jsonl")
        let line = { (s: String) in
            #"{"timestamp":"2026-10-30T08:00:00Z","session_id":"\#(s)","cwd":"/x/p","hook_event_name":"PreToolUse","tool_name":"Grep","tool_detail":"TODO"}"# + "\n"
        }
        append(String(repeating: line("old"), count: 5), to: log)
        var alerts: [(String, String)] = []
        let got = expectation(description: "loop alert")
        let monitor = Monitor(dir: dir) { _ in }
        monitor.onLoop = { alerts.append(($0.session, $1)); got.fulfill() }
        append(String(repeating: line("new"), count: 5), to: log)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(alerts.map(\.0), ["new"])
        XCTAssertEqual(alerts.first?.1, "p: Agent is looping, 1 min\nSame call 5 times: Searching TODO")
    }
}
