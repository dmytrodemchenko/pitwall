import XCTest
@testable import Pitwall

final class SessionStoreTests: XCTestCase {
    var store: SessionStore!

    override func setUp() {
        store = SessionStore()
        store.definedAgents = { _ in [] } // not the real ~/.claude/agents
    }

    private var s1: Session? { store.sessions["s1"] }

    func testStatusTransitions() {
        store.apply(event("SessionStart"))
        XCTAssertEqual(s1?.status, .running)
        XCTAssertEqual(s1?.project, "proj")
        store.apply(event("Notification"))
        XCTAssertEqual(s1?.status, .waiting)
        store.apply(event("PreToolUse", tool: "Bash"))
        XCTAssertEqual(s1?.status, .running)
        store.apply(event("Stop"))
        XCTAssertEqual(s1?.status, .idle)
        XCTAssertEqual(store.activeSessions.count, 1)
        store.apply(event("SessionEnd"))
        XCTAssertEqual(s1?.isEnded, true)
        XCTAssertTrue(store.activeSessions.isEmpty)
    }

    func testGateIsTheAgentAtWork() {
        store.apply(event("PreToolUse", tool: "Agent", agent: "architect"))
        XCTAssertEqual(s1?.gate, "architect")
        store.apply(event("PreToolUse", tool: "Bash")) // the main agent: no change
        store.apply(event("SubagentStop", agent: "angular-developer")) // not a PreToolUse
        XCTAssertEqual(s1?.gate, "architect")
        store.apply(event("PreToolUse", tool: "Bash", agent: "angular-developer")) // resumed via SendMessage
        store.apply(event("PreToolUse", tool: "Agent", agent: "qa-tester"))
        store.apply(event("PreToolUse", tool: "Agent", agent: "architect"))
        XCTAssertEqual(s1?.gate, "architect")
        XCTAssertEqual(s1?.agents, ["architect", "angular-developer", "qa-tester"])
    }

    func testDefinedAgentsFromProjectAndHome() throws {
        let project = tempDir(), home = tempDir()
        for (dir, names) in [(project, ["planner.md", "architect.md", "notes.txt", "general-purpose.md"]), (home, ["architect.md", "qa.md"])] {
            let agents = dir.appending(path: ".claude/agents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            for n in names { try "x".write(to: agents.appending(path: n), atomically: true, encoding: .utf8) }
        }
        // Project first, each once; only .md files; built-in names aren't gates.
        XCTAssertEqual(GateRun.defined(in: project.path, home: home), ["architect", "planner", "qa"])
        XCTAssertEqual(GateRun.defined(in: nil, home: tempDir()), [])
    }

    /// The track shows the project's gates before any ran, gray; ran ones first, in order; built-ins left out.
    func testTrackListsGatesStillToRun() throws {
        store.definedAgents = { _ in ["architect", "developer", "planner", "verifier"] }
        store.apply(event("SessionStart"))
        XCTAssertEqual(PipelineTrack.agents(try XCTUnwrap(s1)), ["architect", "developer", "planner", "verifier"])
        store.apply(event("PreToolUse", tool: "Agent", agent: "planner"))
        store.apply(event("PreToolUse", tool: "Agent", agent: "general-purpose"))
        XCTAssertEqual(PipelineTrack.agents(try XCTUnwrap(s1)), ["planner", "architect", "developer", "verifier"])
        store.definedAgents = { _ in [] }
        store.apply(event("SessionStart", session: "s2"))
        store.apply(event("PreToolUse", session: "s2", tool: "Agent", agent: "Explore"))
        XCTAssertEqual(PipelineTrack.agents(try XCTUnwrap(store.sessions["s2"])), []) // no track for built-ins only
    }

    func testVerifierFailureIsStickyUntilPass() {
        store.apply(event("SubagentStop", agent: "verifier", verdict: "fail"))
        XCTAssertEqual(s1?.status, .failed)
        store.apply(event("Notification"))
        store.apply(event("PreToolUse", tool: "Bash"))
        XCTAssertEqual(s1?.status, .failed)
        store.apply(event("SubagentStop", agent: "verifier", verdict: "pass"))
        XCTAssertEqual(s1?.status, .running)
    }

    func testExpiryAfter30MinutesAndRevival() {
        store.apply(event("SessionStart"))
        store.expire(now: t0 + 29 * 60)
        XCTAssertEqual(s1?.isEnded, false)
        store.expire(now: t0 + 31 * 60)
        XCTAssertEqual(s1?.isEnded, true)
        store.apply(event("PreToolUse", tool: "Bash", at: t0 + 32 * 60))
        XCTAssertEqual(s1?.isEnded, false)
    }

    func testEndedSessionsAreDroppedAfterADay() {
        store.apply(event("SessionStart", session: "old"))
        store.apply(event("SessionEnd", session: "old", at: t0 + 60))
        store.apply(event("SessionStart", session: "new", at: t0 + 20 * 3600))
        XCTAssertEqual(store.expire(now: t0 + 23 * 3600), [])
        XCTAssertNotNil(store.sessions["old"]) // ended, but under a day ago: still offered for Resume
        XCTAssertEqual(store.expire(now: t0 + 25 * 3600), ["old"])
        XCTAssertEqual(Set(store.sessions.keys), ["new"])
    }

    func testAggregateStatusPriority() {
        XCTAssertEqual(store.aggregateStatus, .idle)
        store.apply(event("Stop", session: "a"))
        XCTAssertEqual(store.aggregateStatus, .idle)
        store.apply(event("SessionStart", session: "b"))
        XCTAssertEqual(store.aggregateStatus, .running)
        store.apply(event("Notification", session: "c"))
        XCTAssertEqual(store.aggregateStatus, .waiting)
        store.apply(event("SubagentStop", session: "d", agent: "verifier", verdict: "fail"))
        XCTAssertEqual(store.aggregateStatus, .failed)
        store.apply(event("SessionEnd", session: "d")) // ended sessions don't count
        XCTAssertEqual(store.aggregateStatus, .waiting)
    }

    func testProjectComesFromSessionStartNotLaterCd() {
        store.apply(event("PreToolUse", tool: "Bash", cwd: "/Users/me/proj/hooks"))
        store.apply(event("SessionStart", cwd: "/Users/me/proj"))
        store.apply(event("PreToolUse", tool: "Bash", cwd: "/Users/me/proj/sub"))
        XCTAssertEqual(s1?.project, "proj")
    }

    func testProjectName() {
        XCTAssertEqual(SessionStore.projectName("/Users/me/menu-bar"), "menu-bar")
        XCTAssertEqual(SessionStore.projectName("/Users/me/menu-bar/"), "menu-bar")
        XCTAssertEqual(SessionStore.projectName(nil), "unknown")
    }
}

extension SessionStoreTests {
    func testHeadlineIsWorstThenMostRecent() {
        XCTAssertNil(store.headline)
        store.apply(event("PreToolUse", session: "a", tool: "Agent", agent: "planner", at: t0))
        store.apply(event("PreToolUse", session: "b", tool: "Agent", agent: "developer", at: t0 + 1))
        XCTAssertEqual(store.headline?.id, "b")
        store.apply(event("Notification", session: "a", at: t0 + 2))
        store.apply(event("PreToolUse", session: "b", tool: "Bash", at: t0 + 3))
        XCTAssertEqual(store.headline?.id, "a")
        XCTAssertEqual(MarkState(session: store.headline).gate, "planner")
        XCTAssertEqual(MarkState(session: store.headline).mode, .waiting)
    }
}

extension SessionStoreTests {
    func testToolStartAndPassedTracking() {
        store.apply(event("SessionStart", at: t0))
        store.apply(event("PreToolUse", tool: "Bash", at: t0 + 5))
        XCTAssertEqual(s1?.action?.text, "Running a command")
        XCTAssertEqual(s1?.actionRunning, true)
        XCTAssertEqual(s1?.startedAt, t0)
        store.apply(event("PostToolUse", tool: "Bash", at: t0 + 6))
        XCTAssertEqual(s1?.action?.text, "Running a command") // kept after PostToolUse,
        XCTAssertEqual(s1?.actionRunning, false)                // but shown as finished
        store.apply(event("PreToolUse", tool: "Agent", agent: "verifier"))
        XCTAssertEqual(s1?.action?.text, "Delegating to verifier")
        store.apply(event("SubagentStop", agent: "verifier", verdict: "pass"))
        XCTAssertEqual(s1?.verifierPassed, true)
        XCTAssertEqual(MarkState(session: s1).mode, .passed)
        store.apply(event("PreToolUse", tool: "Agent", agent: "architect"))
        XCTAssertEqual(s1?.verifierPassed, false)
        XCTAssertEqual(MarkState(session: s1).mode, .running)
    }
}
