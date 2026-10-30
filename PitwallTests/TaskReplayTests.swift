import XCTest
@testable import Pitwall

final class TaskReplayTests: XCTestCase {
    private let prices = PriceTable(prices: [
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8),
    ])

    private func ts(_ second: Double) -> String { ISO8601DateFormatter().string(from: t0 + second) }

    private func prompt(_ uuid: String, _ text: String, at s: Double, extra: String = "") -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"\#(ts(s))","cwd":"/x/shop","sessionId":"s1"\#(extra),"message":{"role":"user","content":"\#(text)"}}"#
    }

    private func assistant(_ uuid: String, message: String, at s: Double, block: String, output: Int = 1000) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","timestamp":"\#(ts(s))","cwd":"/x/shop","message":{"id":"\#(message)","model":"claude-opus-5-5","content":[\#(block)],"usage":{"input_tokens":10,"output_tokens":\#(output)}}}"#
    }

    private func tool(_ id: String, _ name: String, _ input: String) -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}"#
    }

    private func result(_ uuid: String, _ id: String, at s: Double, error: Bool = false, text: String = "ok", extra: String = "") -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"\#(ts(s))","cwd":"/x/shop"\#(extra),"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":"\#(text)"}]}}"#
    }

    private func text(_ t: String) -> String { #"{"type":"text","text":"\#(t)"}"# }

    private func write(_ lines: [String], partial: String = "") throws -> URL {
        let url = tempDir().appending(path: "s1.jsonl")
        try (lines.joined(separator: "\n") + "\n" + partial).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One prompt → tool calls with results → final answer; the next prompt starts a new task.
    func testReconstructsTasksFromATranscript() throws {
        let url = try write([
            prompt("p1", "Fix the checkout", at: 0),
            assistant("a1", message: "m1", at: 2, block: tool("t1", "Read", #"{"file_path":"/x/shop/cart.swift"}"#)),
            result("r1", "t1", at: 3),
            assistant("a2", message: "m2", at: 4, block: tool("t2", "Edit", #"{"file_path":"/x/shop/cart.swift"}"#)),
            result("r2", "t2", at: 6, error: true, text: "String to replace not found"),
            assistant("a3", message: "m3", at: 7, block: tool("t3", "Edit", #"{"file_path":"/x/shop/cart.swift"}"#)),
            result("r3", "t3", at: 8),
            assistant("a4", message: "m4", at: 9, block: tool("t4", "Write", #"{"file_path":"/x/shop/new.swift"}"#)),
            result("r4", "t4", at: 10, extra: #","toolUseResult":{"type":"create"}"#),
            assistant("a5", message: "m5", at: 11, block: tool("t5", "Write", #"{"file_path":"/x/shop/old.swift"}"#)),
            result("r5", "t5", at: 12, extra: #","toolUseResult":{"type":"update"}"#),
            assistant("a6", message: "m6", at: 13, block: tool("t6", "Bash", #"{"command":"rm /x/shop/tmp.txt"}"#)),
            result("r6", "t6", at: 14),
            assistant("a7", message: "m7", at: 20, block: text("Fixed: the cart total was off by one.")),
            prompt("p2", "Thanks", at: 60),
            assistant("a8", message: "m8", at: 61, block: text("You're welcome.")),
        ])
        let tasks = TaskReplay.tasks(transcript: url)
        XCTAssertEqual(tasks.map(\.prompt), ["Fix the checkout", "Thanks"])
        let task = tasks[0]
        XCTAssertEqual(task.project, "shop")
        XCTAssertEqual(task.response, "Fixed: the cart total was off by one.")
        XCTAssertEqual(task.duration, 20)
        XCTAssertEqual(task.calls, 6)
        XCTAssertEqual(task.errors, 1)
        XCTAssertTrue(task.isComplete)
        XCTAssertEqual(task.events.first { $0.id == "t2" }?.result, "String to replace not found")
        XCTAssertEqual(task.events.first { $0.id == "t2" }?.duration, 2)
        XCTAssertEqual(task.events.map(\.kind), [.file(.read), .file(.edit), .file(.edit), .file(.create), .file(.edit), .file(.delete), .message])
        XCTAssertEqual(task.files.map(\.path), ["cart.swift", "new.swift", "old.swift", "tmp.txt"], "paths relative to the project; the failed edit adds nothing")
        XCTAssertEqual(task.files.map(\.ops), [[.read, .edit], [.create], [.edit], [.delete]])
        XCTAssertEqual(task.tokens.output, 7000)
        XCTAssertEqual(try XCTUnwrap(task.cost(prices)), (70 * 4 + 7000 * 20) / 1_000_000, accuracy: 1e-12, "the shared price table")
        XCTAssertEqual(tasks[1].duration, 1)
    }

    /// Transcripts repeat lines and split one message over several lines that all carry its usage.
    func testDuplicatesAreCountedOnce() throws {
        let call = assistant("a1", message: "m1", at: 1, block: tool("t1", "Grep", #"{"pattern":"refund"}"#))
        let url = try write([
            prompt("p1", "Find refunds", at: 0), prompt("p1", "Find refunds", at: 0),
            assistant("a0", message: "m1", at: 1, block: text("Searching.")),
            call, call,
            assistant("a1b", message: "m1", at: 1, block: tool("t1", "Grep", #"{"pattern":"refund"}"#)),
            result("r1", "t1", at: 2), result("r1", "t1", at: 2),
        ])
        let tasks = TaskReplay.tasks(transcript: url)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].events.map(\.id), ["m1/\("Searching.".hashValue)", "t1"])
        XCTAssertEqual(tasks[0].usage.count, 1, "usage once per message id")
    }

    /// A transcript cut mid-line or mid-task: the finished part replays, the open call stays open.
    func testIncompleteTranscript() throws {
        let url = try write([
            prompt("p1", "Run the tests", at: 0),
            assistant("a1", message: "m1", at: 5, block: tool("t1", "Bash", #"{"command":"xcodebuild test"}"#)),
        ], partial: #"{"type":"user","uuid":"r1","timestamp":"#)
        let task = try XCTUnwrap(TaskReplay.tasks(transcript: url).first)
        XCTAssertNil(task.response)
        XCTAssertFalse(task.isComplete)
        XCTAssertNil(task.events.first?.end)
        XCTAssertEqual(task.duration, 5)
        XCTAssertTrue(TaskReplay.tasks(transcript: URL(filePath: "/nonexistent.jsonl")).isEmpty)
    }

    /// Text between tool calls is not the answer: a task is complete only when the main agent's turn ended.
    func testCompleteOnlyWhenTheTurnEnded() throws {
        func reply(_ uuid: String, _ stop: String, at s: Double) -> String {
            assistant(uuid, message: uuid, at: s, block: text("Working on it"))
                .replacingOccurrences(of: #""usage""#, with: #""stop_reason":"\#(stop)","usage""#)
        }
        let running = try XCTUnwrap(TaskReplay.tasks(transcript: try write([prompt("p1", "Go", at: 0), reply("a1", "tool_use", at: 1)])).first)
        XCTAssertEqual(running.response, "Working on it")
        XCTAssertFalse(running.isComplete)
        let done = try XCTUnwrap(TaskReplay.tasks(transcript: try write([prompt("p1", "Go", at: 0), reply("a1", "end_turn", at: 1)])).first)
        XCTAssertTrue(done.isComplete)
    }

    /// Subagent transcripts join the task that launched them (by tool_use id) and interleave by time;
    /// equal times keep file order. Their text is not the task's answer.
    func testSubagentEventsAreAttributedAndOrdered() throws {
        let url = try write([
            prompt("p1", "Ship it", at: 0),
            assistant("a1", message: "m1", at: 1, block: tool("t1", "Agent", #"{"subagent_type":"verifier","description":"Verify"}"#)),
            assistant("a2", message: "m2", at: 3, block: tool("t2", "Read", #"{"file_path":"/x/shop/a.swift"}"#)),
            assistant("a3", message: "m3", at: 3, block: tool("t3", "Read", #"{"file_path":"/x/shop/b.swift"}"#)),
            result("r1", "t1", at: 9),
            assistant("a4", message: "m4", at: 10, block: text("Shipped.")),
            prompt("p2", "Next", at: 100),
        ])
        let sub = url.deletingPathExtension().appending(path: "subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try [
            #"{"type":"user","uuid":"s0","isSidechain":true,"timestamp":"\#(ts(1))","message":{"role":"user","content":"Verify"}}"#,
            assistant("s1", message: "sm1", at: 2, block: tool("st1", "Bash", #"{"command":"swift test"}"#), output: 500),
            result("s2", "st1", at: 4, error: true, text: "1 failure"),
            assistant("s3", message: "sm2", at: 8, block: text("VERDICT: FAIL"), output: 500),
        ].joined(separator: "\n").write(to: sub.appending(path: "agent-x.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"verifier","toolUseId":"t1"}"#.write(to: sub.appending(path: "agent-x.meta.json"), atomically: true, encoding: .utf8)

        let tasks = TaskReplay.tasks(transcript: url)
        let task = tasks[0]
        XCTAssertEqual(task.events.map(\.id), ["t1", "st1", "t2", "t3", "sm2/\("VERDICT: FAIL".hashValue)", "m4/\("Shipped.".hashValue)"])
        XCTAssertEqual(task.events.map(\.agent), [nil, "verifier", nil, nil, "verifier", nil])
        XCTAssertEqual(task.response, "Shipped.")
        XCTAssertEqual(task.agents, ["verifier"])
        XCTAssertEqual(task.errors, 1)
        XCTAssertEqual(task.tokens.output, 5000, "the subagent's tokens count toward the task")
        XCTAssertTrue(tasks[1].events.isEmpty)
    }

    /// Slash commands read as typed; meta lines, compaction summaries, command output and tool results are not prompts.
    func testWhatCountsAsAPrompt() throws {
        let url = try write([
            prompt("p0", "/review 42", at: 0),
            prompt("p1", #"<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>42</command-args>"#, at: 0),
            prompt("m1", "Base directory for this skill", at: 1, extra: #","isMeta":true"#),
            prompt("c1", "This session is being continued", at: 2, extra: #","isCompactSummary":true"#),
            prompt("l1", "<local-command-stdout>done</local-command-stdout>", at: 3),
            prompt("n1", "Automated message", at: 4, extra: #","origin":{"kind":"task-notification"}"#),
            prompt("i1", "[Request interrupted by user]", at: 5),
            #"{"type":"system","subtype":"api_error","uuid":"e1","timestamp":"\#(ts(6))","retryAttempt":2,"maxRetries":10,"error":{"message":"Overloaded"}}"#,
            prompt("p2", #"<pasted_content id=\"9\">\nGo on\n</pasted_content id=\"9\">"#, at: 7, extra: #","origin":{"kind":"human"}"#),
        ])
        let tasks = TaskReplay.tasks(transcript: url)
        XCTAssertEqual(tasks.map(\.prompt), ["/review 42", "Go on"], "a command logged twice is one task; paste markers go")
        XCTAssertTrue(tasks[0].interrupted)
        XCTAssertEqual(tasks[0].events.map(\.kind), [.interrupt, .retry])
        XCTAssertEqual(tasks[0].events.last?.title, "API error, retry 2 of 10")
        XCTAssertEqual(tasks[0].retries, 1)
    }

    func testFilters() {
        func e(_ kind: ReplayEvent.Kind, agent: String? = nil, failed: Bool = false) -> ReplayEvent {
            ReplayEvent(id: UUID().uuidString, at: t0, agent: agent, kind: kind, title: "", failed: failed)
        }
        let events = [e(.message), e(.tool), e(.file(.edit)), e(.agent), e(.tool, agent: "verifier"), e(.tool, failed: true), e(.retry)]
        func count(_ f: ReplayFilter) -> Int { events.filter(f.matches).count }
        XCTAssertEqual(count(.all), 7)
        XCTAssertEqual(count(.tools), 5)
        XCTAssertEqual(count(.files), 1)
        XCTAssertEqual(count(.agents), 2)
        XCTAssertEqual(count(.errors), 2)
        XCTAssertEqual(count(.messages), 1)
    }

    /// History: newest first across sessions, unchanged files reuse the cache, and a session scope narrows it.
    @MainActor
    func testHistory() async throws {
        let root = tempDir(), project = root.appending(path: "-x-shop")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (prompt("p1", "Old task", at: 0) + "\n").write(to: project.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)
        try (prompt("p2", "New task", at: 50) + "\n").write(to: project.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)
        let history = TaskHistory(root: root)
        await history.reload()
        XCTAssertEqual(history.tasks.map(\.prompt), ["New task", "Old task"])
        XCTAssertEqual(history.tasks.map(\.session), ["b", "a"])
        history.session = "a"
        XCTAssertEqual(history.shown.map(\.prompt), ["Old task"])
        await history.reload()
        XCTAssertEqual(history.tasks.count, 2)
    }
}
