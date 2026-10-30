import Foundation
import Observation

struct ReplayEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case prompt, message, tool, file(FileOp), agent, agentDone, retry, interrupt, end
    }

    enum FileOp: String, CaseIterable {
        case read, create, edit, delete
    }

    let id: String
    let at: Date
    var agent: String?
    var kind: Kind
    var title: String
    var tool: String?
    var subagent: String?
    var detail: String?
    var path: String?
    var end: Date?
    var failed = false
    var result: String?
    var approximate = false

    var isCall: Bool {
        switch kind {
        case .tool, .file, .agent: true
        default: false
        }
    }

    var duration: TimeInterval? { end.map { max(0, $0.timeIntervalSince(at)) } }
}

enum ReplayFilter: String, CaseIterable, Identifiable {
    case all = "All", tools = "Tools", files = "Files", agents = "Agents", errors = "Errors", messages = "Messages"

    var id: Self { self }

    func matches(_ e: ReplayEvent) -> Bool {
        switch self {
        case .all: true
        case .tools: e.isCall
        case .files: if case .file = e.kind { true } else { false }
        case .agents: e.agent != nil || e.kind == .agent || e.kind == .agentDone
        case .errors: e.failed || e.kind == .retry || e.kind == .interrupt
        case .messages: [.prompt, .message, .end].contains(e.kind)
        }
    }
}

struct ReplayTask: Identifiable, Equatable {
    let id: String
    let session: String
    var project: String
    let prompt: String
    var response: String?
    let start: Date
    var end: Date
    var events: [ReplayEvent] = []
    var usage: [UsageEntry] = []
    var usageByAgent: [String: [UsageEntry]] = [:]
    var interrupted = false
    var stopReason: String?

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var calls: Int { events.filter(\.isCall).count }
    var errors: Int { events.filter { $0.failed && $0.kind != .retry }.count }
    var retries: Int { events.filter { $0.kind == .retry }.count }
    var tokens: TokenUsage { usage.tokens }
    var isComplete: Bool { response != nil && !interrupted && (stopReason ?? "end_turn") == "end_turn" }

    var agents: [String] {
        var seen = Set<String>()
        return events.compactMap(\.agent).filter { seen.insert($0).inserted }
    }

    var files: [FileActivity] {
        var order: [String] = [], found: [String: FileActivity] = [:]
        for e in events {
            guard case .file(let op) = e.kind, let path = e.path, !e.failed else { continue }
            if found[path] == nil { order.append(path) }
            var f = found[path] ?? FileActivity(path: path, ops: [], agents: [], first: e.at, last: e.at)
            if !f.ops.contains(op) { f.ops = ReplayEvent.FileOp.allCases.filter { f.ops.contains($0) || $0 == op } }
            if !f.agents.contains(e.agent) { f.agents.append(e.agent) }
            f.last = max(f.last, e.at)
            found[path] = f
        }
        return order.compactMap { found[$0] }
    }

    func cost(_ prices: PriceTable) -> Double? { prices.cost(of: usage) }

    func contributions(_ prices: PriceTable) -> [AgentContribution] {
        ([nil] + agents.map(Optional.some)).map { name in
            let own = events.filter { $0.agent == name }
            let entries = usageByAgent[name ?? ""] ?? []
            let runs = events.filter { $0.kind == .agent && $0.subagent == name }.compactMap(\.duration)
            let span = own.map(\.at).min().flatMap { a in own.map { $0.end ?? $0.at }.max().map { $0.timeIntervalSince(a) } }
            let time = name == nil ? duration : runs.isEmpty ? span ?? 0 : runs.reduce(0, +)
            return AgentContribution(agent: name, calls: own.filter(\.isCall).count, time: time, tokens: entries.tokens,
                                     cost: prices.cost(of: entries))
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.end == b.end && a.events == b.events && a.response == b.response
    }
}

struct FileActivity: Equatable {
    let path: String
    var ops: [ReplayEvent.FileOp]
    var agents: [String?]
    var first, last: Date

    var changed: Bool { ops.contains { $0 != .read } }
}

struct AgentContribution: Equatable {
    let agent: String?
    let calls: Int
    let time: TimeInterval
    let tokens: TokenUsage
    let cost: Double?
}

enum TaskReplay {
    static let previewLimit = 600, responseLimit = 8000, noPrompt = "(no prompt recorded)"
    private static let typeFirst = Data(#"{"type":""#.utf8)
    private static let kept = ["user", "assistant", "system"].map { Data(#"{"type":"\#($0)""#.utf8) }
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true), plain = Date.ISO8601FormatStyle()

    static func tasks(transcript url: URL) -> [ReplayTask] {
        var b = Builder(session: url.deletingPathExtension().lastPathComponent)
        for line in lines(url) { b.add(line, agent: nil) }
        let dir = url.deletingPathExtension().appending(path: "subagents")
        let subagents = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        for sub in subagents {
            let meta = (try? Data(contentsOf: sub.deletingPathExtension().appendingPathExtension("meta.json")))
                .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            b.subagent(lines(sub), agent: meta?.agentType.flatMap { $0.isEmpty ? nil : $0 } ?? "subagent",
                       toolUse: meta?.toolUseId)
        }
        return b.finish()
    }

    static func lines(_ url: URL) -> [Data] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
    }

    static func prompt(_ text: String) -> String {
        guard let name = tag("command-name", in: text) else {
            return text.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n\s*\n(\s*\n)+"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let args = tag("command-args", in: text) ?? ""
        return (name.hasPrefix("/") ? name : "/" + name) + (args.isEmpty ? "" : " " + args)
    }

    static func preview(_ text: String, limit: Int = previewLimit) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? t.prefix(limit) + "…" : t
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let a = text.range(of: "<\(name)>"), let b = text.range(of: "</\(name)>", range: a.upperBound..<text.endIndex)
        else { return nil }
        return text[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Meta: Decodable {
        let agentType: String?
        let toolUseId: String?
    }

    private struct Builder {
        let session: String
        var tasks: [ReplayTask] = []
        var seenLines = Set<String>(), seenMessages = Set<String>(), calls: [String: (task: Int, event: Int)] = [:]
        var seq = 0, order: [String: Int] = [:], lastAt: Date?, approximate = false

        init(session: String) { self.session = session }

        mutating func subagent(_ lines: [Data], agent: String, toolUse: String?) {
            var target = toolUse.flatMap { calls[$0]?.task }
            lastAt = nil
            for line in lines {
                guard let d = object(line), let at = time(d), isNew(d) else { continue }
                if target == nil { target = tasks.lastIndex { $0.start <= at } ?? (tasks.isEmpty ? nil : 0) }
                guard let target else { return }
                add(d, line: line, at: at, task: target, agent: agent)
            }
        }

        mutating func add(_ line: Data, agent: String?) {
            guard let d = object(line), let at = time(d), isNew(d) else { return }
            let agent = d["isSidechain"] as? Bool == true ? "subagent" : agent
            if d["type"] as? String == "user", agent == nil, let text = Self.promptText(d) {
                if text.hasPrefix("[Request interrupted") {
                    guard !tasks.isEmpty else { return }
                    tasks[tasks.count - 1].interrupted = true
                    append(ReplayEvent(id: d["uuid"] as? String ?? "i\(seq)", at: at, kind: .interrupt,
                                       title: "Interrupted by the user"), to: tasks.count - 1)
                    return
                }
                let cwd = d["cwd"] as? String, prompt = TaskReplay.prompt(text)
                if let last = tasks.last, last.events.allSatisfy({ $0.kind == .prompt }), last.usage.isEmpty, last.prompt == prompt { return }
                tasks.append(ReplayTask(id: d["uuid"] as? String ?? "\(session)#\(tasks.count)", session: session,
                                        project: SessionStore.projectName(cwd), prompt: prompt, start: at, end: at))
                append(ReplayEvent(id: tasks[tasks.count - 1].id + "/prompt", at: at, kind: .prompt,
                                   title: TaskReplay.preview(prompt, limit: 160), detail: TaskReplay.preview(prompt)), to: tasks.count - 1)
                return
            }
            if tasks.isEmpty, ["assistant", "user"].contains(d["type"] as? String) {
                tasks.append(ReplayTask(id: "\(session)#0", session: session, project: SessionStore.projectName(d["cwd"] as? String),
                                        prompt: TaskReplay.noPrompt, start: at, end: at))
            }
            guard !tasks.isEmpty else { return }
            add(d, line: line, at: at, task: tasks.count - 1, agent: agent)
        }

        private mutating func add(_ d: [String: Any], line: Data, at: Date, task t: Int, agent: String?) {
            tasks[t].end = max(tasks[t].end, at)
            let cwd = d["cwd"] as? String
            switch d["type"] as? String {
            case "assistant":
                guard let message = d["message"] as? [String: Any] else { return }
                if let record = UsageRecord.parse(line), seenMessages.insert(record.messageID).inserted {
                    let entry = UsageEntry(model: record.entry.model, timestamp: at, tokens: record.entry.tokens)
                    tasks[t].usage.append(entry)
                    tasks[t].usageByAgent[agent ?? "", default: []].append(entry)
                }
                if agent == nil, let stop = message["stop_reason"] as? String { tasks[t].stopReason = stop }
                for block in message["content"] as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !text.isEmpty else { continue }
                        let id = "\(message["id"] as? String ?? "m\(seq)")/\(text.hashValue)"
                        guard seenLines.insert(id).inserted else { continue }
                        if agent == nil { tasks[t].response = TaskReplay.preview(text, limit: TaskReplay.responseLimit) }
                        append(ReplayEvent(id: id, at: at, agent: agent, kind: .message,
                                           title: TaskReplay.preview(text, limit: 160), detail: TaskReplay.preview(text)), to: t)
                    case "tool_use":
                        guard let id = block["id"] as? String, calls[id] == nil else { continue }
                        let name = block["name"] as? String ?? "tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        var e = Self.call(id: id, name: name, input: input, at: at, cwd: cwd)
                        e.agent = agent
                        calls[id] = (t, tasks[t].events.count)
                        append(e, to: t)
                    default: continue
                    }
                }
            case "user":
                guard let blocks = (d["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
                let structured = d["toolUseResult"] as? [String: Any]
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String, let (ti, ei) = calls[id], ei < tasks[ti].events.count else { continue }
                    var e = tasks[ti].events[ei]
                    guard e.end == nil else { continue }
                    e.end = at
                    e.failed = block["is_error"] as? Bool ?? false
                    e.result = Self.text(block["content"]).map { TaskReplay.preview($0) }
                    if case .file(.create) = e.kind, structured?["type"] as? String == "update" { e.kind = .file(.edit) }
                    tasks[ti].events[ei] = e
                    tasks[ti].end = max(tasks[ti].end, at)
                }
            case "system" where d["subtype"] as? String == "api_error":
                let attempt = d["retryAttempt"] as? Int, max = d["maxRetries"] as? Int
                let error = ((d["error"] as? [String: Any])?["message"] as? String) ?? (d["content"] as? String)
                append(ReplayEvent(id: d["uuid"] as? String ?? "r\(seq)", at: at, agent: agent, kind: .retry,
                                   title: attempt.map { "API error, retry \($0)" + (max.map { " of \($0)" } ?? "") } ?? "API error",
                                   detail: error.map { TaskReplay.preview($0) }, failed: true), to: t)
            default:
                return
            }
        }

        private mutating func isNew(_ d: [String: Any]) -> Bool {
            (d["uuid"] as? String).map { seenLines.insert($0).inserted } ?? true
        }

        private mutating func time(_ d: [String: Any]) -> Date? {
            if let at = date(d["timestamp"]) {
                lastAt = at
                approximate = false
                return at
            }
            approximate = true
            return lastAt
        }

        private mutating func append(_ e: ReplayEvent, to t: Int) {
            var e = e
            e.approximate = approximate
            order[e.id] = seq
            seq += 1
            tasks[t].events.append(e)
            tasks[t].end = max(tasks[t].end, e.at)
        }

        func finish() -> [ReplayTask] {
            tasks.filter { $0.prompt != TaskReplay.noPrompt || !$0.events.isEmpty }.map { task in
                var task = task, order = order
                for e in task.events where e.kind == .agent {
                    guard let end = e.end else { continue }
                    let name = e.subagent ?? "agent"
                    let done = ReplayEvent(id: e.id + "/done", at: end, agent: e.subagent, kind: .agentDone,
                                           title: e.failed ? "\(name) failed" : "\(name) finished", result: e.result)
                    order[done.id] = order[e.id].map { $0 + 1 } ?? 0
                    task.events.append(done)
                }
                let end = ReplayEvent(id: task.id + "/end", at: task.end, kind: .end,
                                      title: task.isComplete ? "Task completed"
                                          : task.interrupted ? "Stopped: interrupted by the user"
                                          : "No final response in the transcript")
                order[end.id] = Int.max
                task.events.append(end)
                task.events.sort { ($0.at, order[$0.id] ?? 0) < ($1.at, order[$1.id] ?? 0) }
                return task
            }
        }

        static func call(id: String, name: String, input: [String: Any], at: Date, cwd: String?) -> ReplayEvent {
            let keys = ["file_path", "notebook_path", "command", "pattern", "url", "query", "description", "prompt"]
            let detail = keys.lazy.compactMap { input[$0] as? String }.first
            let path = (input["file_path"] ?? input["notebook_path"]) as? String
            let action = ToolAction.describe(tool: name, detail: detail, subagent: input["subagent_type"] as? String, cwd: cwd)
            let kind: ReplayEvent.Kind
            switch name {
            case "Read": kind = .file(.read)
            case "Write": kind = .file(.create)
            case "Edit", "MultiEdit", "NotebookEdit": kind = .file(.edit)
            case "Task", "Agent": kind = .agent
            case "Bash" where (detail ?? "").range(of: #"^\s*(sudo\s+)?(rm|git\s+rm|trash)\s"#, options: .regularExpression) != nil:
                kind = .file(.delete)
            default: kind = .tool
            }
            let title = name == "Write" ? action.text.replacingOccurrences(of: "Editing", with: "Writing") : action.text
            return ReplayEvent(id: id, at: at, kind: kind, title: title, tool: name,
                               subagent: kind == .agent ? input["subagent_type"] as? String : nil, detail: action.full == action.text ? detail : action.full,
                               path: (kind == .file(.delete) ? removed(detail) : path).map { ToolAction.shorten($0, cwd: cwd, home: NSHomeDirectory()) })
        }

        static func removed(_ command: String?) -> String? {
            let line = command?.split(whereSeparator: \.isNewline).first ?? ""
            let words = line.split(separator: " ").drop { !["rm", "trash"].contains($0) }.dropFirst()
            let files = words.prefix { !["&&", ";", "|"].contains($0) }.filter { !$0.hasPrefix("-") }
            return files.isEmpty ? nil : files.joined(separator: " ")
        }

        static func promptText(_ d: [String: Any]) -> String? {
            guard d["isMeta"] as? Bool != true, d["isCompactSummary"] as? Bool != true,
                  ((d["origin"] as? [String: Any])?["kind"] as? String).map({ $0 == "human" }) ?? true,
                  let content = (d["message"] as? [String: Any])?["content"] else { return nil }
            let text: String
            if let s = content as? String {
                text = s
            } else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                return nil
            }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("<local-command-"), !t.hasPrefix("<task-notification>"),
                  !t.hasPrefix("<system-reminder>") else { return nil }
            return t
        }

        static func text(_ content: Any?) -> String? {
            if let s = content as? String { return s }
            guard let blocks = content as? [[String: Any]] else { return nil }
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }

        private func object(_ line: Data) -> [String: Any]? {
            if line.starts(with: TaskReplay.typeFirst), !TaskReplay.kept.contains(where: { line.starts(with: $0) }) { return nil }
            return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        }

        private func date(_ value: Any?) -> Date? {
            guard let s = value as? String else { return nil }
            return (try? TaskReplay.fractional.parse(s)) ?? (try? TaskReplay.plain.parse(s))
        }
    }
}

@MainActor @Observable
final class TaskHistory {
    static let days = 7.0, limit = 40

    var tasks: [ReplayTask] = []
    var loading = false
    var session: String?
    @ObservationIgnored let root: URL
    @ObservationIgnored private var cache: [String: Scan.Entry] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")) {
        self.root = root
    }

    var shown: [ReplayTask] { session.map { s in tasks.filter { $0.session == s } } ?? tasks }

    func reload(now: Date = Date()) async {
        guard !loading else { return }
        loading = true
        let root = root, old = cache, since = now - Self.days * 86400, limit = Self.limit
        let scanned = await Task.detached(priority: .utility) { await Scan.run(root: root, cache: old, since: since, limit: limit) }.value
        cache = scanned
        tasks = scanned.values.flatMap(\.tasks).sorted { $0.start > $1.start }
        loading = false
    }
}

enum Scan {
    struct Entry {
        let stamp: String
        let tasks: [ReplayTask]
    }

    static func run(root: URL, cache: [String: Entry], since: Date, limit: Int) async -> [String: Entry] {
        let fm = FileManager.default, keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let files = dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys)) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date, Int)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), let date = v.contentModificationDate, date >= since
                else { return nil }
                return (url, date, v.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return await withTaskGroup(of: (String, Entry).self) { group in
            for (url, date, size) in files {
                let stamp = "\(date.timeIntervalSince1970)/\(size)"
                if let cached = cache[url.path], cached.stamp == stamp {
                    group.addTask { (url.path, cached) }
                } else {
                    group.addTask { (url.path, Entry(stamp: stamp, tasks: TaskReplay.tasks(transcript: url))) }
                }
            }
            var result: [String: Entry] = [:]
            for await (path, entry) in group { result[path] = entry }
            return result
        }
    }
}
