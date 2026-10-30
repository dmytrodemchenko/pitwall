import XCTest
@testable import Pitwall

final class ToolActionTests: XCTestCase {
    private func text(_ tool: String, _ detail: String? = nil, agent: String? = nil) -> String {
        ToolAction.describe(tool: tool, detail: detail, subagent: agent).text
    }

    func testMapping() {
        XCTAssertEqual(text("Edit", "/x/src/App.swift"), "Editing App.swift")
        XCTAssertEqual(text("Write", "/x/README.md"), "Editing README.md")
        XCTAssertEqual(text("MultiEdit", "/x/a.ts"), "Editing a.ts")
        XCTAssertEqual(text("NotebookEdit", "/x/n.ipynb"), "Editing n.ipynb")
        XCTAssertEqual(text("Read", "/x/plan.md"), "Reading plan.md")
        XCTAssertEqual(text("Bash", "git status"), "Running git status")
        XCTAssertEqual(text("PowerShell", "Get-ChildItem"), "Running Get-ChildItem")
        XCTAssertEqual(text("Grep", "func handleRefund"), "Searching func handleRefund")
        XCTAssertEqual(text("Glob", "**/*.swift"), "Searching **/*.swift")
        XCTAssertEqual(text("WebFetch", "https://www.example.com/docs/a?b=1"), "Browsing example.com")
        XCTAssertEqual(text("WebSearch", "swift observation"), "Browsing swift observation")
        XCTAssertEqual(text("Agent", agent: "planner"), "Delegating to planner")
        XCTAssertEqual(text("Task", agent: "verifier"), "Delegating to verifier")
        XCTAssertEqual(text("ToolSearch"), "Using ToolSearch")
        XCTAssertEqual(text("mcp__github__create_issue"), "Using create_issue (github)")
    }

    func testMissingDetail() {
        XCTAssertEqual(text("Edit"), "Editing a file")
        XCTAssertEqual(text("Bash", "   "), "Running a command")
        XCTAssertEqual(text("Agent"), "Delegating to an agent")
        XCTAssertEqual(text("WebFetch", "not a url"), "Browsing not a url")
    }

    func testBashIsCutAt40AndTooltipHasItAll() {
        let command = "xcodebuild -project Pitwall.xcodeproj -scheme Pitwall test"
        let a = ToolAction.describe(tool: "Bash", detail: command, subagent: nil)
        XCTAssertEqual(a.text, "Running " + command.prefix(40) + "…")
        XCTAssertEqual(a.full, "Running " + command)
        let exactly40 = String(repeating: "a", count: 40)
        XCTAssertEqual(text("Bash", exactly40), "Running " + exactly40)
        XCTAssertEqual(text("Bash", "cd x\nmake"), "Running cd x…") // only the first line
        // A heredoc: the program, not the raw `<<'EOF'`; the tooltip keeps the script.
        XCTAssertEqual(text("Bash", "python3 - <<'EOF'\nprint(1)\nEOF"), "Running python3 script")
        XCTAssertEqual(text("Bash", "cd /x && /usr/bin/node <<EOF 2>&1\nx\nEOF"), "Running node script")
        XCTAssertEqual(ToolAction.describe(tool: "Bash", detail: "cat <<-\"END\"\nhi\nEND", subagent: nil).full, "Running cat <<-\"END\"\nhi\nEND")
        XCTAssertEqual(text("Bash", "echo $((1 << 2))"), "Running echo $((1 << 2))") // a shift, not a heredoc
    }

    func testPathsAreShortAndCdIsSkipped() {
        func action(_ command: String) -> ToolAction {
            ToolAction.describe(tool: "Bash", detail: command, subagent: nil, cwd: "/Users/me/work/app", home: "/Users/me")
        }
        XCTAssertEqual(action("cd /Users/me/work/app && npm test").text, "Running npm test")
        XCTAssertEqual(action("cd /Users/me/work/app && npm test").full, "Running cd . && npm test")
        XCTAssertEqual(action("cd \"/Users/me/other dir\"; cd sub && make -C /Users/me/work/app/lib").text, "Running make -C lib")
        XCTAssertEqual(action("cd /Users/me/work/other").text, "Running cd ~/work/other")
        XCTAssertEqual(action("ls /Users/me/work/app /Users/me/work/apps").text, "Running ls . ~/work/apps")
        XCTAssertEqual(ToolAction.describe(tool: "Read", detail: "/Users/me/work/app/src/a.ts", subagent: nil,
                                           cwd: "/Users/me/work/app", home: "/Users/me").full, "Reading src/a.ts")
    }

    func testTooltipHasTheFullPath() {
        XCTAssertEqual(ToolAction.describe(tool: "Read", detail: "/x/plan.md", subagent: nil).full, "Reading /x/plan.md")
        XCTAssertEqual(ToolAction.describe(tool: "mcp__github__create_issue", detail: nil, subagent: nil).full,
                       "Using mcp__github__create_issue")
    }
}
