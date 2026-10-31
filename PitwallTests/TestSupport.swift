import Foundation
import XCTest
@testable import Pitwall

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func event(_ name: String, session: String = "s1", tool: String? = nil, agent: String? = nil,
           verdict: String? = nil, cwd: String? = "/Users/me/proj", at: Date = t0) -> HookEvent {
    HookEvent(timestamp: at, sessionId: session, cwd: cwd, hookEventName: name, transcriptPath: "/t.jsonl",
              toolName: tool, subagentType: agent, verdict: verdict)
}

/// Stamped now: Monitor only loads today's backlog, so a fixed date breaks the day after.
func jsonLine(_ name: String, session: String = "s1") -> String {
    #"{"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","session_id":"\#(session)","cwd":"/p","hook_event_name":"\#(name)","transcript_path":null,"tool_name":null,"subagent_type":null,"verdict":null}"# + "\n"
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func append(_ text: String, to url: URL) {
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    } else {
        try! text.write(to: url, atomically: false, encoding: .utf8)
    }
}

extension UsageStore {
    /// `refresh`, waiting until its result is published on main.
    func refreshAndWait(session: String, transcriptPath: String) {
        let done = XCTestExpectation(description: "usage refreshed")
        refresh(session: session, transcriptPath: transcriptPath) { done.fulfill() }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 5), .completed)
    }
}

/// events.jsonl with session "s1" started now, whose transcript is 50 MB of one repeated assistant message.
func writeBigSession(in dir: URL) throws {
    let now = ISO8601DateFormatter().string(from: Date()), transcript = dir.appending(path: "sess.jsonl")
    let line = usageLine(id: "m", ts: now)
        .replacingOccurrences(of: #""role":"assistant","#, with: #""role":"assistant","content":"\#(String(repeating: "x", count: 2000))","#)
    try String(repeating: line, count: (50 << 20) / line.utf8.count).write(to: transcript, atomically: true, encoding: .utf8)
    let hook = #"{"timestamp":"\#(now)","session_id":"s1","cwd":"/x/p","hook_event_name":"SessionStart","transcript_path":"\#(transcript.path)"}"#
    try (hook + "\n").write(to: dir.appending(path: "events.jsonl"), atomically: true, encoding: .utf8)
}
