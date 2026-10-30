import XCTest
@testable import Pitwall

final class CollisionTests: XCTestCase {
    private func edit(_ session: String, _ file: String, cwd: String = "/x/shop", at minute: Double) -> HookEvent {
        var e = event("PreToolUse", session: session, tool: "Edit", cwd: cwd, at: t0 + minute * 60)
        e.toolDetail = file
        return e
    }

    func testTwoSessionsEditingOneFile() throws {
        var d = CollisionDetector()
        XCTAssertNil(d.observe(edit("a", "/x/shop/cart.ts", at: 0)))
        XCTAssertNil(d.observe(edit("a", "/x/shop/cart.ts", at: 1)), "same session")
        XCTAssertNil(d.observe(edit("b", "/x/shop/other.ts", at: 2)))
        let c = try XCTUnwrap(d.observe(edit("b", "cart.ts", at: 3)), "relative to the session folder")
        XCTAssertEqual(c.file, "/x/shop/cart.ts")
        XCTAssertEqual(c.other, "a")
        XCTAssertNil(d.observe(edit("a", "/x/shop/cart.ts", at: 4)), "once per pair and file")
        XCTAssertNotNil(d.observe(edit("c", "/x/shop/cart.ts", at: 5)))
    }

    func testOldEditsAndEndedSessionsDontCount() {
        var d = CollisionDetector()
        XCTAssertNil(d.observe(edit("a", "/p/cart.ts", at: 0)))
        XCTAssertNil(d.observe(edit("b", "/p/cart.ts", at: 31)), "outside the window")
        XCTAssertNil(d.observe(event("SessionEnd", session: "b", at: t0 + 32 * 60)))
        XCTAssertNil(d.observe(edit("c", "/p/cart.ts", at: 33)))
        var read = edit("d", "/p/cart.ts", at: 34)
        read = HookEvent(timestamp: read.timestamp, sessionId: "d", cwd: nil, hookEventName: "PreToolUse",
                         transcriptPath: nil, toolName: "Read", toolDetail: "/p/cart.ts", subagentType: nil, verdict: nil)
        XCTAssertNil(d.observe(read), "reads don't collide")
    }

    func testMessage() {
        XCTAssertEqual(CollisionDetector.message(file: "/x/cart.ts", projects: ("shop", "api")), "shop and api are both editing cart.ts")
        XCTAssertEqual(CollisionDetector.message(file: "/x/cart.ts", projects: ("shop", "shop")), "Two shop sessions are editing cart.ts")
    }

    @MainActor
    func testMonitorAlertsLiveCollisions() throws {
        let dir = tempDir(), log = dir.appending(path: "events.jsonl")
        let line = { (s: String, cwd: String) in
            #"{"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","session_id":"\#(s)","cwd":"\#(cwd)","hook_event_name":"PreToolUse","tool_name":"Edit","tool_detail":"/x/shop/cart.ts"}"# + "\n"
        }
        append(line("old1", "/x/shop") + line("old2", "/x/shop"), to: log)
        var alerts: [String] = []
        let got = expectation(description: "collision alert")
        let monitor = Monitor(dir: dir) { alerts.append($0); got.fulfill() }
        monitor.cacheMinCost = { 0 }
        append(line("new", "/x/api"), to: log)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(alerts, ["api and shop are both editing cart.ts"])
    }
}
