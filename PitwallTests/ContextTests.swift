import XCTest
@testable import Pitwall

@MainActor
final class ContextTests: XCTestCase {
    private func line(_ id: String, _ time: String, model: String = "claude-opus-5-5",
                      input: Int, read: Int, write: Int, output: Int = 500) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"output_tokens":\#(output),"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":\#(write)}}}}"#
    }

    func testContextIsTheLastMainMessageInputSide() throws {
        let dir = tempDir()
        let transcript = dir.appending(path: "s1.jsonl")
        try [line("m1", "2026-10-30T09:00:00.100Z", input: 10, read: 1_000, write: 200),
             line("m2", "2026-10-30T09:01:00.100Z", input: 6, read: 150_000, write: 4_000, output: 9_999)]
            .joined(separator: "\n").appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
        // A subagent's bigger context must not count as the session's.
        let sub = dir.appending(path: "s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try line("x1", "2026-10-30T09:02:00Z", input: 1, read: 900_000, write: 0).appending("\n")
            .write(to: sub.appending(path: "agent-1.jsonl"), atomically: true, encoding: .utf8)

        let usage = UsageStore()
        usage.refreshAndWait(session: "s1", transcriptPath: transcript.path)
        XCTAssertEqual(usage.contexts["s1"], ContextUsage(tokens: 154_006, model: "claude-opus-5-5",
                                                          at: usage.contexts["s1"]!.at)) // output tokens excluded

        // Only new lines are read: an appended turn (e.g. after /compact) updates it.
        append(line("m3", "2026-10-30T09:03:00Z", input: 3, read: 20_000, write: 1_000) + "\n", to: transcript)
        usage.refreshAndWait(session: "s1", transcriptPath: transcript.path)
        XCTAssertEqual(usage.contexts["s1"]?.tokens, 21_003)
    }

    func testWindowPerModel() throws {
        let windows = try XCTUnwrap(Mock.contextWindows) // the bundled context.json
        XCTAssertEqual(windows.window(for: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(windows.window(for: "claude-fable-5-1"), 1_000_000)
        XCTAssertEqual(windows.window(for: "claude-sonnet-4-6"), 200_000)
        XCTAssertEqual(windows.window(for: "claude-opus-4-6"), 200_000)
        XCTAssertEqual(windows.window(for: "something-else"), 200_000)
        let custom = try XCTUnwrap(ContextWindows.decode(Data(#"{"default":100,"models":{"a":1,"ab":2}}"#.utf8)))
        XCTAssertEqual(custom.window(for: "abc"), 2)
        XCTAssertEqual(custom.window(for: "x"), 100)
        XCTAssertNil(ContextWindows.decode(Data("{}".utf8)))
    }

    func testPercentAndLevels() {
        let c = ContextUsage(tokens: 150_000, model: "m", at: t0)
        XCTAssertEqual(c.percent(of: 200_000), 75)
        XCTAssertEqual(ContextLevel(percent: 69.9, warn: 70, alert: 85), .normal)
        XCTAssertEqual(ContextLevel(percent: 70, warn: 70, alert: 85), .warning)
        XCTAssertEqual(ContextLevel(percent: 85, warn: 70, alert: 85), .warning)
        XCTAssertEqual(ContextLevel(percent: 85.1, warn: 70, alert: 85), .critical)
        XCTAssertEqual(ContextLevel(percent: 50, warn: 40, alert: 45), .critical) // thresholds come from Settings
    }

    func testOneAlertPerSessionAndNoneForTheBacklog() throws {
        let dir = tempDir()
        let transcript = dir.appending(path: "s1.jsonl")
        let full = line("m1", ISO8601DateFormatter().string(from: Date()), model: "claude-sonnet-4-6", input: 1, read: 180_000, write: 0)
        try (full + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        func hookLine(_ name: String) -> String {
            #"{"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","session_id":"s1","cwd":"/x/proj","hook_event_name":"\#(name)","transcript_path":"\#(transcript.path)"}"#
        }
        let log = dir.appending(path: "events.jsonl")
        try (hookLine("SessionStart") + "\n").write(to: log, atomically: true, encoding: .utf8)

        var alerts: [String] = []
        let monitor = Monitor(dir: dir) { alerts.append($0) } // the backlog is already 90% full: no replay
        monitor.contextThresholds = { (70, 85) }
        XCTAssertEqual(alerts, [])

        // A second session crosses 85% live: exactly one alert, even as it keeps growing.
        let t2 = dir.appending(path: "s2.jsonl")
        try (line("n1", ISO8601DateFormatter().string(from: Date()), model: "claude-sonnet-4-6", input: 1, read: 100_000, write: 0) + "\n")
            .write(to: t2, atomically: true, encoding: .utf8)
        let s2 = { (name: String) in hookLine(name).replacingOccurrences(of: "\"s1\"", with: "\"s2\"")
            .replacingOccurrences(of: transcript.path, with: t2.path) }
        append(s2("SessionStart") + "\n", to: log)
        let quiet = expectation(description: "below threshold: no alert")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 0.5)
        XCTAssertEqual(alerts, [])
        for read in [175_000, 190_000] {
            append(line("n\(read)", ISO8601DateFormatter().string(from: Date()), model: "claude-sonnet-4-6", input: 1, read: read, write: 0) + "\n", to: t2)
            append(s2("PostToolUse") + "\n", to: log)
            let seen = expectation(for: NSPredicate { _, _ in monitor.usage.contexts["s2"]?.tokens == read + 1 }, evaluatedWith: nil)
            wait(for: [seen], timeout: 3)
        }
        XCTAssertEqual(alerts, ["proj: context 87% full"])
    }
}
