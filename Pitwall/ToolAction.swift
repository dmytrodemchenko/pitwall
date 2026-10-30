import Foundation

struct ToolAction: Equatable {
    let text: String
    let full: String

    static let commandLimit = 40

    init(text: String, full: String? = nil) {
        self.text = text
        self.full = full ?? text
    }

    static func describe(tool: String, detail: String?, subagent: String?, cwd: String? = nil,
                         home: String = NSHomeDirectory()) -> ToolAction {
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { shorten($0, cwd: cwd, home: home) }
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return ToolAction(text: "Editing \(file(detail))", full: detail.map { "Editing \($0)" })
        case "Read":
            return ToolAction(text: "Reading \(file(detail))", full: detail.map { "Reading \($0)" })
        case "Bash", "PowerShell":
            guard let command = detail else { return ToolAction(text: "Running a command") }
            let first = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            let line = first.replacingOccurrences(of: #"^(\s*cd\s+("[^"]*"|'[^']*'|\S+)\s*(&&|;)\s*)+"#, with: "",
                                                  options: .regularExpression).nilIfEmpty ?? first
            if let program = heredocProgram(line) {
                return ToolAction(text: "Running \(program) script", full: "Running \(command)")
            }
            let short = line.count > commandLimit || first != command ? line.prefix(commandLimit) + "…" : line
            return ToolAction(text: "Running \(short)", full: "Running \(command)")
        case "Grep", "Glob":
            return ToolAction(text: "Searching \(detail ?? "files")")
        case "WebFetch":
            let host = detail.flatMap { URL(string: $0)?.host() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            return ToolAction(text: "Browsing \(host ?? detail ?? "the web")", full: detail.map { "Browsing \($0)" })
        case "WebSearch":
            return ToolAction(text: "Browsing \(detail ?? "the web")")
        case "Task", "Agent":
            return ToolAction(text: "Delegating to \(subagent ?? "an agent")")
        default:
            return ToolAction(text: "Using \(displayName(tool))", full: "Using \(tool)")
        }
    }

    static func heredocProgram(_ line: String) -> String? {
        guard line.range(of: #"<<-?\s*['"]?[A-Za-z_]\w*"#, options: .regularExpression) != nil else { return nil }
        let segment = line.components(separatedBy: CharacterSet(charactersIn: ";|&")).first { $0.contains("<<") } ?? line
        return segment.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }
    }

    static func shorten(_ text: String, cwd: String?, home: String) -> String {
        var text = text
        for (path, short) in [(cwd, "."), (home, "~")] {
            guard let path, path.count > 1 else { continue }
            let p = path.hasSuffix("/") ? String(path.dropLast()) : path
            text = text.replacingOccurrences(of: p + "/", with: short == "." ? "" : "~/")
            text = text.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: p) + #"(?=$|[\s"';&|)])"#, with: short,
                                             options: .regularExpression)
        }
        return text
    }

    private static func file(_ path: String?) -> String {
        path.map { ($0 as NSString).lastPathComponent } ?? "a file"
    }

    private static func displayName(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return tool }
        return "\(parts[2...].joined(separator: "__")) (\(parts[1]))"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
