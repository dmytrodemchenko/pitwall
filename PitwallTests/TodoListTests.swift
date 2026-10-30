import XCTest
@testable import Pitwall

final class TodoListTests: XCTestCase {
    func testTodoWriteReplacesTheList() {
        var list: [Todo] = []
        list.apply(todos: [Todo(content: "a", status: "completed"), Todo(content: "b", status: "in_progress")], task: nil)
        XCTAssertEqual(list.completed, 1)
        XCTAssertEqual(list.inProgress?.content, "b")
        list.apply(todos: [Todo(content: "c", status: "pending")], task: nil)
        XCTAssertEqual(list.map(\.content), ["c"])
    }

    func testTaskCreateUpdateDelete() {
        var list: [Todo] = []
        list.apply(todos: nil, task: TaskChange(id: "1", subject: "Write tests", status: "pending"))
        list.apply(todos: nil, task: TaskChange(id: "2", subject: "Ship it", status: "pending"))
        list.apply(todos: nil, task: TaskChange(id: "1", status: "in_progress"))
        XCTAssertEqual(list.inProgress?.content, "Write tests")
        list.apply(todos: nil, task: TaskChange(id: "1", status: "completed"))
        XCTAssertEqual(list.completed, 1)
        XCTAssertEqual(list.count, 2)
        list.apply(todos: nil, task: TaskChange(id: "2", status: "deleted"))
        XCTAssertEqual(list.map(\.content), ["Write tests"])
        list.apply(todos: nil, task: TaskChange(id: nil, status: "completed")) // no id: ignored
        list.apply(todos: nil, task: TaskChange(id: "9", status: "in_progress")) // unknown id: added
        XCTAssertEqual(list.last, Todo(id: "9", content: "Task 9", status: "in_progress"))
    }

    /// The hook's lines decode into the session (shapes captured from real Claude Code payloads).
    func testHookLinesReachTheSession() throws {
        let lines = [
            #"{"timestamp":"2026-10-30T09:00:00Z","session_id":"s1","hook_event_name":"PostToolUse","tool_name":"TaskCreate","task":{"id":"1","subject":"Write tests","status":"pending"}}"#,
            #"{"timestamp":"2026-10-30T09:00:01Z","session_id":"s1","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","task":{"id":"1","subject":null,"status":"in_progress"}}"#,
        ]
        let store = SessionStore()
        for line in lines { store.apply(try XCTUnwrap(HookEvent.parse(Data(line.utf8)))) }
        XCTAssertEqual(store.sessions["s1"]?.todos, [Todo(id: "1", content: "Write tests", status: "in_progress")])

        let write = #"{"timestamp":"2026-10-30T09:00:02Z","session_id":"s1","hook_event_name":"PostToolUse","tool_name":"TodoWrite","todos":[{"content":"x","status":"completed"}]}"#
        store.apply(try XCTUnwrap(HookEvent.parse(Data(write.utf8))))
        XCTAssertEqual(store.sessions["s1"]?.todos, [Todo(id: nil, content: "x", status: "completed")])
    }
}
