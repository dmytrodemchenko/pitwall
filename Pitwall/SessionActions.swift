import AppKit
import Observation

struct ActionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor @Observable
final class SessionActions {
    static let ideCommandKey = "ideCommand", defaultIDECommand = "webstorm", terminalKey = "terminalApp"
    nonisolated static let general = ""

    var errors: [String: String] = [:]
    @ObservationIgnored var showSettings: () -> Void = {}
    @ObservationIgnored var showReplay: (String?) -> Void = { _ in }
    @ObservationIgnored var defaults = UserDefaults.standard

    var ideCommand: String {
        let command = defaults.string(forKey: Self.ideCommandKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return command.isEmpty ? Self.defaultIDECommand : command
    }

    var terminalForNewTabs: String {
        if let app = defaults.string(forKey: Self.terminalKey), TerminalFocus.canOpenTabs(app) { return app }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalFocus.iTerm) != nil
            ? TerminalFocus.iTerm : TerminalFocus.terminal
    }

    func openTerminal(_ s: Session) {
        report(s.id) { try TerminalFocus.focus(tty: s.tty, app: s.terminalApp) }
    }

    func newSession(in folder: String, errorKey: String = general) {
        report(errorKey) { try TerminalFocus.openTab(app: terminalForNewTabs, folder: folder, command: "claude") }
    }

    func resume(_ s: Session) {
        guard let folder = s.folder else {
            errors[s.id] = "This session's project folder isn't known."
            return
        }
        guard s.id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
            errors[s.id] = "“\(s.id)” doesn't look like a session id."
            return
        }
        let app = s.terminalApp.flatMap { TerminalFocus.canOpenTabs($0) ? $0 : nil } ?? terminalForNewTabs
        report(s.id) { try TerminalFocus.openTab(app: app, folder: folder, command: "claude --resume \(s.id)") }
    }

    func stop(_ s: Session, confirm: @MainActor (Session) -> Bool = SessionActions.confirmStop) {
        guard let pid = s.pid else {
            errors[s.id] = "This session's process isn't known yet. It's recorded when Claude next finishes a turn."
            return
        }
        guard Self.isClaudeProcess(pid) else {
            errors[s.id] = "Claude Code (process \(pid)) isn't running anymore."
            return
        }
        guard confirm(s) else { return }
        if kill(pid, SIGINT) == 0 {
            errors[s.id] = nil
        } else {
            errors[s.id] = "Couldn't stop process \(pid): \(String(cString: strerror(errno)))."
        }
    }

    static func confirmStop(_ s: Session) -> Bool {
        let alert = stopAlert(s)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func stopAlert(_ s: Session) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Stop Claude Code in “\(s.project)”?"
        alert.informativeText = "Folder: \(s.folder ?? "unknown")\n\n"
            + "This sends Ctrl-C (SIGINT) to process \(s.pid ?? 0) and Claude Code exits. You can resume the session later."
        alert.addButton(withTitle: "Stop").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func isClaudeProcess(_ pid: pid_t) -> Bool {
        if isClaudeCommandLine(arguments(pid)) { return true }
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).contains("/claude/versions/")
    }

    static func isClaudeCommandLine(_ argv: [String]) -> Bool {
        switch argv.first.map({ ($0 as NSString).lastPathComponent }) {
        case "claude": true
        case "node": argv.dropFirst().contains { $0.contains("claude-code") }
        default: false
        }
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var argv: [String] = []
        while argv.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            argv.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return argv
    }

    func openIDE(_ s: Session) {
        guard let folder = s.folder else {
            errors[s.id] = "This session's project folder isn't known."
            return
        }
        let command = ideCommand
        errors[s.id] = nil
        Self.run("/bin/zsh", Self.loginShellArguments(command, argument: folder), label: command) { [weak self] status, failure in
            guard status == 127, !command.contains(" ") else {
                self?.errors[s.id] = failure
                return
            }
            Self.run("/usr/bin/open", ["-a", command, folder], label: "open -a \(command)") { status, _ in
                self?.errors[s.id] = status == 0 ? nil
                    : "“\(command)” isn't a command on your PATH, and there's no app named “\(command)”. Set the IDE command in Settings."
            }
        }
    }

    private func report(_ key: String, _ action: () throws -> Void) {
        do {
            try action()
            errors[key] = nil
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    static func run(_ executable: String, _ arguments: [String], label: String,
                    done: @escaping @MainActor @Sendable (Int32, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { p in
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            let status = p.terminationStatus
            let failure = status == 0 ? nil : "“\(label)” failed (exit \(status))" + (message.isEmpty ? "." : ": \(message)")
            Task { @MainActor in done(status, failure) }
        }
        do {
            try process.run()
        } catch {
            Task { @MainActor in done(-1, "Couldn't run “\(label)”: \(error.localizedDescription)") }
        }
    }

    static func loginShellArguments(_ command: String, argument: String) -> [String] {
        ["-lc", "\(command) \"$1\"", "zsh", argument]
    }
}

enum TerminalFocus {
    static let iTerm = "com.googlecode.iterm2", terminal = "com.apple.Terminal"

    static func canOpenTabs(_ app: String) -> Bool { app == iTerm || app == terminal }

    static func openTab(app: String, folder: String, command: String) throws {
        guard let source = newTabScript(app: app, commandLine: "cd \(shellQuote(folder)) && \(command)") else {
            throw ActionError("New sessions open in iTerm2 or Terminal.app; \(appName(app)) can't be scripted.")
        }
        _ = try run(source, appName: appName(app))
    }

    static func newTabScript(app: String, commandLine: String) -> String? {
        let text = appleScriptString(commandLine)
        switch app {
        case iTerm:
            return """
            tell application id "\(iTerm)"
                activate
                if (count of windows) is 0 then
                    create window with default profile
                else
                    tell current window to create tab with default profile
                end if
                tell current session of current window to write text \(text)
            end tell
            """
        case terminal:
            return """
            tell application id "\(terminal)"
                activate
                do script \(text)
            end tell
            """
        default:
            return nil
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func focus(tty: String?, app: String?) throws {
        guard let app else {
            throw ActionError("This session's terminal isn't known yet. It's recorded when Claude next finishes a turn.")
        }
        let name = appName(app)
        if let tty, let source = script(app: app, tty: tty) {
            guard try run(source, appName: name) == "ok" else {
                throw ActionError("No \(name) tab is using \(tty). The session may have been closed.")
            }
            return
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else {
            throw ActionError("\(name) isn't running.")
        }
        running.activate()
    }

    static func script(app: String, tty: String) -> String? {
        guard tty.range(of: #"^/dev/tty[a-z0-9]+$"#, options: .regularExpression) != nil else { return nil }
        switch app {
        case iTerm:
            return """
            tell application id "\(iTerm)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        case terminal:
            return """
            tell application id "\(terminal)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
        default:
            return nil
        }
    }

    static func run(_ source: String, appName: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            throw ActionError(message(forAppleScriptError: number, appName: appName,
                                      detail: error[NSAppleScript.errorMessage] as? String))
        }
        return result?.stringValue ?? ""
    }

    static func message(forAppleScriptError number: Int, appName: String, detail: String?) -> String {
        switch number {
        case -1743:
            "Pitwall isn't allowed to control \(appName). Turn it on in System Settings → Privacy & Security → Automation."
        case -600:
            "\(appName) isn't running."
        default:
            "\(appName) didn't respond (AppleScript error \(number)\(detail.map { ": \($0)" } ?? ""))."
        }
    }

    static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}
