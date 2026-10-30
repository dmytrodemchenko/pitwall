import XCTest
@testable import Pitwall

final class ConfigImpactTests: XCTestCase {
    func testParsesGitLog() {
        let log = "@1800000000\n\n.claude/agents/planner.md\nCLAUDE.md\n@1799990000\n\n.claude/agents/verifier.md\n"
        let changes = ConfigChange.parse(log: log)
        XCTAssertEqual(changes.map(\.at), [t0, t0 - 10000])
        XCTAssertEqual(changes.map(\.label), ["planner prompt, CLAUDE.md", "verifier prompt"])
    }

    func testFailureRateBeforeAndAfterEachChange() {
        let verdicts = ["fail", "fail", "pass", "pass", "pass", "fail", "pass", "pass", "pass", "pass"]
        let runs = verdicts.enumerated().map { i, v in
            GateRunItem(session: "s", gate: "verifier", start: t0, end: t0 + Double(i) * 3600, verdict: v)
        }
        let changes = [ConfigChange(at: t0 + 2.5 * 3600, files: ["planner"]), ConfigChange(at: t0 + 9.5 * 3600, files: ["CLAUDE.md"])]
        let impacts = ConfigImpact.compare(changes: changes, runs: runs, project: "p", pattern: Verifier.defaultPattern)
        XCTAssertEqual(impacts.map(\.before), [.init(runs: 3, failures: 2), .init(runs: 7, failures: 1)])
        XCTAssertEqual(impacts.map(\.after), [.init(runs: 7, failures: 1), .init(runs: 0, failures: 0)])
        XCTAssertEqual(impacts.map(\.isMeasured), [true, false])
    }

    /// A burst of saves with no verifier run in between is one change, compared from before the first to after the last.
    func testEditsWithNoRunInBetweenAreOneChange() {
        let runs = ["fail", "pass", "pass"].enumerated().map { i, v in
            GateRunItem(session: "s", gate: "verifier", start: t0, end: t0 + Double(i) * 3600, verdict: v)
        }
        let changes = [0.5, 0.6, 0.7].map { ConfigChange(at: t0 + $0 * 3600, files: ["CLAUDE.md"]) }
            + [ConfigChange(at: t0 + 0.8 * 3600, files: [".claude/agents/planner.md"])]
        let impacts = ConfigImpact.compare(changes: changes, runs: runs, project: "p", pattern: Verifier.defaultPattern)
        XCTAssertEqual(impacts.map(\.change.files), [["CLAUDE.md", ".claude/agents/planner.md"]])
        XCTAssertEqual(impacts.map(\.change.at), [t0 + 0.8 * 3600])
        XCTAssertEqual(impacts.map(\.before), [.init(runs: 1, failures: 1)])
        XCTAssertEqual(impacts.map(\.after), [.init(runs: 2, failures: 0)])
    }

    /// Snapshots catch edits git can't see (.claude/ and CLAUDE.md are often git-ignored), git covers the time before.
    func testSnapshotsAndGitHistory() throws {
        let dir = tempDir(), home = tempDir()
        let history = ConfigHistory(url: tempDir().appending(path: "config-history.json"), home: home)
        let git = { (args: [String]) in XCTAssertNotNil(Git.run(["-C", dir.path] + args, timeout: 5), args.joined(separator: " ")) }
        git(["init", "-q"])
        try FileManager.default.createDirectory(at: dir.appending(path: ".claude/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/agents"), withIntermediateDirectories: true)
        try "plan".write(to: dir.appending(path: ".claude/agents/planner.md"), atomically: true, encoding: .utf8)
        try "check".write(to: home.appending(path: ".claude/agents/verifier.md"), atomically: true, encoding: .utf8)
        git(["add", "-f", "."])
        git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "agents"])

        let now = Date() + 60, since = now - 3600
        XCTAssertEqual(history.changes(in: dir.path, since: since, now: now).map(\.files), [[".claude/agents/planner.md"]]) // git, before the first snapshot
        try "rules".write(to: dir.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        try "check more".write(to: home.appending(path: ".claude/agents/verifier.md"), atomically: true, encoding: .utf8)
        let changes = history.changes(in: dir.path, since: since, now: now + 1)
        XCTAssertEqual(changes.map(\.files), [[".claude/agents/planner.md"], ["CLAUDE.md", "~/.claude/agents/verifier.md"]])
        XCTAssertEqual(changes.last?.label, "CLAUDE.md, verifier prompt")
        XCTAssertEqual(history.changes(in: dir.path, since: since, now: now + 2).count, 2) // nothing new
        let mode = try FileManager.default.attributesOfItem(atPath: history.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testStoreKeepsTheFolderAndComparesPerProject() async throws {
        let now = Date(), change = ConfigChange(at: now - 5 * 3600, files: [".claude/agents/planner.md"])
        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true),
                                   configChanges: { folder, _ in folder == "/x/shop" ? [change] : [] })
        let dir = tempDir(), log = dir.appending(path: "events.jsonl")
        let iso = ISO8601DateFormatter()
        var lines = ""
        for (i, v) in ["fail", "fail", "pass", "pass", "pass", "pass", "fail", "pass"].enumerated() {
            let start = now - Double(9 - i) * 3600
            lines += #"{"timestamp":"\#(iso.string(from: start))","session_id":"s\#(i)","cwd":"/x/shop","hook_event_name":"PreToolUse","tool_name":"Agent","subagent_type":"verifier"}"# + "\n"
            lines += #"{"timestamp":"\#(iso.string(from: start + 60))","session_id":"s\#(i)","cwd":"/x/shop","hook_event_name":"SubagentStop","subagent_type":"verifier","verdict":"\#(v)"}"# + "\n"
        }
        try lines.write(to: log, atomically: true, encoding: .utf8)
        await store.ingestEvents(url: log)
        let impacts = await store.configImpacts(pattern: Verifier.defaultPattern, now: now)
        XCTAssertEqual(impacts.count, 1)
        XCTAssertEqual(impacts.first?.project, "shop")
        XCTAssertEqual(impacts.first?.before, .init(runs: 4, failures: 2))
        XCTAssertEqual(impacts.first?.after, .init(runs: 4, failures: 1))
    }
}
