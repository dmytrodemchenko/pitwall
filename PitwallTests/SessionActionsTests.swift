import XCTest
@testable import Pitwall

@MainActor
final class SessionActionsTests: XCTestCase {
    func testHookEventCarriesProcessInfo() throws {
        let line = #"{"timestamp":"2026-10-30T08:49:20Z","session_id":"x","cwd":"/p","hook_event_name":"Stop","pid":65152,"tty":"/dev/ttys000","terminal_app":"com.googlecode.iterm2"}"#
        let e = try XCTUnwrap(HookEvent.parse(Data(line.utf8)))
        XCTAssertEqual(e.pid, 65152)
        XCTAssertEqual(e.tty, "/dev/ttys000")
        XCTAssertEqual(e.terminalApp, "com.googlecode.iterm2")
    }

    func testSessionKeepsProcessAndFolder() {
        let store = SessionStore()
        var stop = event("Stop", cwd: "/Users/me/proj/sub")
        stop.pid = 42
        stop.tty = "/dev/ttys003"
        stop.terminalApp = TerminalFocus.terminal
        store.apply(stop)
        store.apply(event("SessionStart", cwd: "/Users/me/proj"))
        store.apply(event("PreToolUse", tool: "Bash", cwd: "/Users/me/proj/other")) // no pid on busy events
        let s = store.sessions["s1"]
        XCTAssertEqual(s?.folder, "/Users/me/proj")
        XCTAssertEqual(s?.pid, 42)
        XCTAssertEqual(s?.tty, "/dev/ttys003")
        XCTAssertEqual(s?.terminalApp, TerminalFocus.terminal)
    }

    func testScriptsMatchTheTTY() throws {
        let iterm = try XCTUnwrap(TerminalFocus.script(app: TerminalFocus.iTerm, tty: "/dev/ttys000"))
        XCTAssertTrue(iterm.contains(#"if tty of s is "/dev/ttys000""#))
        let terminal = try XCTUnwrap(TerminalFocus.script(app: TerminalFocus.terminal, tty: "/dev/ttys012"))
        XCTAssertTrue(terminal.contains(#"if tty of t is "/dev/ttys012""#))
        XCTAssertNil(TerminalFocus.script(app: "dev.warp.Warp-Stable", tty: "/dev/ttys000")) // app activation only
        // The events file is user-writable: nothing but a plain tty path ever reaches AppleScript.
        XCTAssertNil(TerminalFocus.script(app: TerminalFocus.iTerm, tty: #"/dev/ttys0" & do shell script "touch /tmp/x" & ""#))
    }

    func testFocusFailuresExplainThemselves() {
        XCTAssertThrowsError(try TerminalFocus.focus(tty: "/dev/ttys000", app: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("isn't known yet"))
        }
        XCTAssertThrowsError(try TerminalFocus.focus(tty: nil, app: "com.example.not-installed")) {
            XCTAssertTrue($0.localizedDescription.contains("isn't running"))
        }
        XCTAssertTrue(TerminalFocus.message(forAppleScriptError: -1743, appName: "iTerm2", detail: nil).contains("Automation"))
    }

    func testFailedActionShowsOnTheCard() {
        let actions = SessionActions()
        let s = Session(id: "s1", project: "proj", folder: nil, startedAt: t0, lastEventAt: t0)
        actions.openTerminal(s)
        XCTAssertNotNil(actions.errors["s1"])
        actions.openIDE(s)
        XCTAssertEqual(actions.errors["s1"], "This session's project folder isn't known.")
    }

    func testIDECommandFromSettings() {
        let actions = SessionActions()
        actions.defaults = UserDefaults(suiteName: "test-\(UUID())")!
        XCTAssertEqual(actions.ideCommand, "webstorm")
        actions.defaults.set("  code -n ", forKey: SessionActions.ideCommandKey)
        XCTAssertEqual(actions.ideCommand, "code -n")
        // The folder is $1, never spliced into the command.
        XCTAssertEqual(SessionActions.loginShellArguments("code -n", argument: "/a b/$(rm)"),
                       ["-lc", #"code -n "$1""#, "zsh", "/a b/$(rm)"])
    }

    func testIDECommandFailureIsReported() {
        let actions = SessionActions()
        actions.defaults = UserDefaults(suiteName: "test-\(UUID())")!
        actions.defaults.set("no-such-ide-command-xyz", forKey: SessionActions.ideCommandKey)
        let s = Session(id: "s1", project: "proj", folder: "/tmp", startedAt: t0, lastEventAt: t0)
        actions.openIDE(s)
        let reported = expectation(for: NSPredicate { _, _ in actions.errors["s1"] != nil }, evaluatedWith: nil)
        wait(for: [reported], timeout: 10)
        // Not on PATH, and no app by that name either: says both, and where to fix it.
        XCTAssertTrue(actions.errors["s1"]!.contains("no-such-ide-command-xyz"))
        XCTAssertTrue(actions.errors["s1"]!.contains("no app named"))
    }

    // MARK: Quick actions

    func testNewTabCommandIsQuoted() throws {
        XCTAssertEqual(TerminalFocus.shellQuote("/a b/it's"), #"'/a b/it'\''s'"#)
        XCTAssertEqual(TerminalFocus.appleScriptString(#"say "hi" \ there"#), #""say \"hi\" \\ there""#)
        let iterm = try XCTUnwrap(TerminalFocus.newTabScript(app: TerminalFocus.iTerm, commandLine: "cd '/p' && claude"))
        XCTAssertTrue(iterm.contains(#"write text "cd '/p' && claude""#))
        XCTAssertTrue(iterm.contains("create tab with default profile"))
        let terminal = try XCTUnwrap(TerminalFocus.newTabScript(app: TerminalFocus.terminal, commandLine: "claude"))
        XCTAssertTrue(terminal.contains(#"do script "claude""#))
        XCTAssertNil(TerminalFocus.newTabScript(app: "dev.warp.Warp-Stable", commandLine: "claude"))
    }

    /// Compiles (never runs) every script against the installed apps' dictionaries.
    func testScriptsCompile() throws {
        for app in [TerminalFocus.iTerm, TerminalFocus.terminal] {
            try XCTSkipIf(NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) == nil, "\(app) not installed")
            for source in [TerminalFocus.script(app: app, tty: "/dev/ttys000"),
                           TerminalFocus.newTabScript(app: app, commandLine: "cd '/tmp' && claude --resume abc-123")] {
                var error: NSDictionary?
                XCTAssertTrue(NSAppleScript(source: try XCTUnwrap(source))!.compileAndReturnError(&error), "\(app): \(String(describing: error))")
            }
        }
    }

    func testTerminalForNewTabsFollowsSettings() {
        let actions = SessionActions()
        actions.defaults = UserDefaults(suiteName: "test-\(UUID())")!
        actions.defaults.set(TerminalFocus.terminal, forKey: SessionActions.terminalKey)
        XCTAssertEqual(actions.terminalForNewTabs, TerminalFocus.terminal)
        actions.defaults.set("dev.warp.Warp-Stable", forKey: SessionActions.terminalKey) // not scriptable: ignored
        XCTAssertTrue(TerminalFocus.canOpenTabs(actions.terminalForNewTabs))
    }

    func testResumeRefusesBadInput() {
        let actions = SessionActions()
        actions.resume(Session(id: "s1", project: "p", folder: nil, startedAt: t0, lastEventAt: t0))
        XCTAssertEqual(actions.errors["s1"], "This session's project folder isn't known.")
        let odd = #"x; rm -rf ~"#
        actions.resume(Session(id: odd, project: "p", folder: "/tmp", startedAt: t0, lastEventAt: t0))
        XCTAssertTrue(actions.errors[odd]!.contains("doesn't look like a session id"))
    }

    func testRecentFoldersAreUniqueNewestFirst() {
        let store = SessionStore()
        store.apply(event("SessionStart", session: "a", cwd: "/p/one", at: t0))
        store.apply(event("SessionStart", session: "b", cwd: "/p/two", at: t0 + 10))
        store.apply(event("SessionStart", session: "c", cwd: "/p/one", at: t0 + 20))
        store.apply(event("SessionEnd", session: "c", cwd: "/p/one", at: t0 + 30)) // ended sessions still count
        XCTAssertEqual(store.recentFolders, ["/p/one", "/p/two"])
        XCTAssertEqual(store.recentSessions.map(\.id), ["c", "b", "a"])
    }

    func testStopNeedsAKnownLiveClaudeProcess() throws {
        let actions = SessionActions()
        var s = Session(id: "s1", project: "p", folder: "/tmp", startedAt: t0, lastEventAt: t0)
        actions.stop(s) { _ in XCTFail("no pid: must not ask"); return false }
        XCTAssertTrue(actions.errors["s1"]!.contains("isn't known yet"))

        // A reused pid that is no longer Claude Code is never signalled.
        let other = try spawn("/bin/sleep", named: "sleep")
        defer { other.terminate() }
        s.pid = other.processIdentifier
        actions.stop(s) { _ in XCTFail("not claude: must not ask"); return false }
        XCTAssertTrue(actions.errors["s1"]!.contains("isn't running anymore"))
        XCTAssertTrue(other.isRunning)
    }

    func testStopAsksThenSendsSIGINT() throws {
        let claude = try spawn("/bin/sleep", named: "claude") // a process the kernel calls "claude"
        defer { if claude.isRunning { claude.terminate() } }
        let actions = SessionActions()
        var s = Session(id: "s1", project: "p", folder: "/tmp", startedAt: t0, lastEventAt: t0)
        s.pid = claude.processIdentifier
        XCTAssertTrue(SessionActions.isClaudeProcess(claude.processIdentifier))

        var asked = 0
        actions.stop(s) { _ in asked += 1; return false } // Cancel
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(claude.isRunning)

        actions.stop(s) { _ in asked += 1; return true } // Stop
        claude.waitUntilExit()
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(claude.terminationReason, .uncaughtSignal)
        XCTAssertEqual(claude.terminationStatus, SIGINT)
        XCTAssertNil(actions.errors["s1"])
    }

    func testNodeCountsOnlyWhenItRunsClaudeCode() {
        XCTAssertTrue(SessionActions.isClaudeCommandLine(["claude", "--resume", "x"]))
        XCTAssertTrue(SessionActions.isClaudeCommandLine(["/usr/local/bin/claude"]))
        XCTAssertTrue(SessionActions.isClaudeCommandLine(["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
        XCTAssertTrue(SessionActions.isClaudeCommandLine(["/opt/homebrew/bin/node", "/x/claude-code/cli.js", "-c"]))
        XCTAssertFalse(SessionActions.isClaudeCommandLine(["node", "server.js"]))
        XCTAssertFalse(SessionActions.isClaudeCommandLine(["node"]))
        XCTAssertFalse(SessionActions.isClaudeCommandLine(["sleep", "claude-code"]))
        XCTAssertFalse(SessionActions.isClaudeCommandLine([]))
    }

    func testReadsTheArguments() throws {
        let p = try spawn("/bin/sleep", named: "claude")
        defer { p.terminate() }
        XCTAssertEqual(SessionActions.arguments(p.processIdentifier).map { ($0 as NSString).lastPathComponent }, ["claude", "30"])
    }

    func testRecognisesTheRealClaudeCode() throws {
        // The Claude Code running this machine's sessions, when there is one (the kernel names it after its version).
        let pids = try XCTUnwrap(String(data: try runOutput("/usr/bin/pgrep", ["-x", "claude"]), encoding: .utf8))
            .split(separator: "\n").compactMap { pid_t($0) }
        try XCTSkipIf(pids.isEmpty, "no Claude Code running")
        XCTAssertTrue(pids.contains { SessionActions.isClaudeProcess($0) })
        XCTAssertFalse(SessionActions.isClaudeProcess(getpid()))
    }

    private func runOutput(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return out.fileHandleForReading.readDataToEndOfFile()
    }

    /// Starts `sleep 30` through a symlink, so it is launched as `name`.
    private func spawn(_ binary: String, named name: String) throws -> Process {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appending(path: name)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: binary)
        let p = Process()
        p.executableURL = link
        p.arguments = ["30"]
        try p.run()
        return p
    }
}
