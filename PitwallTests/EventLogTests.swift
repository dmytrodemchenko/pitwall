import XCTest
@testable import Pitwall

final class HookEventTests: XCTestCase {
    func testFullLine() throws {
        let line = #"{"timestamp":"2026-10-30T08:00:00Z","session_id":"s1","cwd":"/a/proj","hook_event_name":"PreToolUse","transcript_path":"/t.jsonl","tool_name":"Agent","subagent_type":"planner","verdict":null}"#
        let e = try XCTUnwrap(HookEvent.parse(Data(line.utf8)))
        XCTAssertEqual(e.sessionId, "s1")
        XCTAssertEqual(e.hookEventName, "PreToolUse")
        XCTAssertEqual(e.toolName, "Agent")
        XCTAssertEqual(e.subagentType, "planner")
        XCTAssertNil(e.verdict)
        XCTAssertEqual(e.timestamp, ISO8601DateFormatter().date(from: "2026-10-30T08:00:00Z"))
    }

    func testMissingOptionalFields() {
        let line = #"{"timestamp":"2026-10-30T08:00:00Z","session_id":"s1","hook_event_name":"Stop"}"#
        XCTAssertNotNil(HookEvent.parse(Data(line.utf8)))
    }

    func testMalformedLinesAreSkipped() {
        XCTAssertNil(HookEvent.parse(Data("not json".utf8)))
        XCTAssertNil(HookEvent.parse(Data(#"{"timestamp":"2026-10-30T08:00:00Z","session_id":null,"hook_event_name":"Stop"}"#.utf8)))
        XCTAssertNil(HookEvent.parse(Data()))
    }
}

final class EventLogReaderTests: XCTestCase {
    var url: URL!
    var reader: EventLogReader!

    override func setUp() {
        url = tempDir().appending(path: "events.jsonl")
        reader = EventLogReader(url: url)
    }

    func testMissingFileReturnsNothing() {
        XCTAssertEqual(reader.readNew().count, 0)
    }

    func testReadsOnlyNewLines() {
        append(jsonLine("SessionStart") + jsonLine("PreToolUse"), to: url)
        XCTAssertEqual(reader.readNew().map(\.hookEventName), ["SessionStart", "PreToolUse"])
        append(jsonLine("Stop"), to: url)
        XCTAssertEqual(reader.readNew().map(\.hookEventName), ["Stop"])
        XCTAssertEqual(reader.readNew().count, 0)
    }

    func testPartialLineWaitsForNewline() {
        let line = jsonLine("Stop")
        let cut = line.index(line.startIndex, offsetBy: 20)
        append(String(line[..<cut]), to: url)
        XCTAssertEqual(reader.readNew().count, 0)
        append(String(line[cut...]), to: url)
        XCTAssertEqual(reader.readNew().map(\.hookEventName), ["Stop"])
    }

    func testGarbageLineSkipped() {
        append("garbage\n" + jsonLine("Stop"), to: url)
        XCTAssertEqual(reader.readNew().map(\.hookEventName), ["Stop"])
    }

    func testTruncationStartsOver() throws {
        append(jsonLine("SessionStart") + jsonLine("Stop"), to: url)
        _ = reader.readNew()
        try jsonLine("Notification").write(to: url, atomically: false, encoding: .utf8)
        XCTAssertEqual(reader.readNew().map(\.hookEventName), ["Notification"])
    }

    func testReplacedFileStartsOver() throws {
        append(jsonLine("SessionStart"), to: url)
        _ = reader.readNew()
        // Atomic write = new inode, even though the new file is bigger.
        try (jsonLine("Notification") + jsonLine("Stop")).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.readNew().map(\.hookEventName), ["Notification", "Stop"])
    }
}

final class EventLogWatcherTests: XCTestCase {
    func testFiresOnCreateAppendAndReplace() throws {
        let url = tempDir().appending(path: "events.jsonl")
        let reader = EventLogReader(url: url)
        let created = expectation(description: "created")
        let appended = expectation(description: "appended")
        let replaced = expectation(description: "replaced")
        var seen = 0

        let watcher = EventLogWatcher(url: url, queue: .main) {
            let before = seen
            seen += reader.readNew().count
            for (n, exp) in [(1, created), (2, appended), (3, replaced)] where before < n && seen >= n {
                exp.fulfill()
            }
        }

        append(jsonLine("SessionStart"), to: url) // file does not exist yet: directory watch
        wait(for: [created], timeout: 2)
        let start = Date()
        append(jsonLine("PreToolUse"), to: url)   // file watch
        wait(for: [appended], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "S2.5: store must update within ~1s")
        try FileManager.default.removeItem(at: url)
        append(jsonLine("Stop"), to: url)         // re-armed after delete
        wait(for: [replaced], timeout: 2)
        withExtendedLifetime(watcher) {}
    }
}

@MainActor
final class EventLogRotationTests: XCTestCase {
    private let now = Date()

    /// One session per day for 30 days, each with an architect run; written an hour ago (no session active).
    private func thirtyDayLog() throws -> URL {
        let dir = tempDir(), url = dir.appending(path: "events.jsonl")
        let f = ISO8601DateFormatter()
        var text = ""
        for day in (0..<30).reversed() { // oldest first, like the real log
            let start = now - Double(day) * 86400 - 3600
            func line(_ name: String, _ at: Date, tool: String = "null", agent: String = "null") -> String {
                #"{"timestamp":"\#(f.string(from: at))","session_id":"d\#(day)","cwd":"/p\#(day)","hook_event_name":"\#(name)","tool_name":\#(tool),"subagent_type":\#(agent)}"# + "\n"
            }
            text += line("SessionStart", start) + line("PreToolUse", start + 60, tool: #""Agent""#, agent: #""architect""#)
                + line("SubagentStop", start + 180, agent: #""architect""#)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now - 3600], ofItemAtPath: url.path)
        return url
    }

    func testKeepsTheLastSevenDays() async throws {
        let url = try thirtyDayLog()
        XCTAssertTrue(EventLogRotation.rotate(url, now: now))
        let events = EventLogReader(url: url).readNew()
        XCTAssertEqual(events.count, 7 * 3)
        XCTAssertTrue(events.allSatisfy { $0.timestamp >= now - EventLogRotation.keep })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["events.jsonl"])

        let sessions = SessionStore()
        events.forEach(sessions.apply)
        XCTAssertEqual(Set(sessions.sessions.keys), Set((0..<7).map { "d\($0)" }))
        XCTAssertTrue((0..<7).allSatisfy { sessions.sessions["d\($0)"]?.gateRuns["architect"]?.end != nil })
        let monitor = Monitor(dir: url.deletingLastPathComponent()) { _ in }
        XCTAssertEqual(Set(monitor.store.sessions.keys), ["d0"]) // the menu keeps only the last day
        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true))
        await store.ingestEvents(url: url)
        let runs = await store.gateRuns(since: .distantPast)
        XCTAssertEqual(runs.count, 7)
        XCTAssertTrue(runs.allSatisfy { $0.gate == "architect" && $0.duration == 120 })
        XCTAssertFalse(EventLogRotation.rotate(url, now: now)) // nothing old left
    }

    func testLeavesALogInUseAlone() throws {
        let url = try thirtyDayLog()
        try FileManager.default.setAttributes([.modificationDate: now - 60], ofItemAtPath: url.path)
        XCTAssertFalse(EventLogRotation.rotate(url, now: now))
        XCTAssertEqual(EventLogReader(url: url).readNew().count, 30 * 3)
    }

    func testMissingLogIsFine() {
        XCTAssertFalse(EventLogRotation.rotate(tempDir().appending(path: "events.jsonl")))
    }
}
