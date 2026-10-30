import Foundation

@MainActor
enum Demo {
    static let key = "demo"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    static let folder = ["s1": "storefront", "s2": "payments-api", "s3": "mobile-app"]

    static func todos(done: Int) -> [Todo] {
        ["Model the cart totals", "Add the discount line", "Show taxes per region", "Write the checkout tests", "Update the docs"]
            .enumerated().map { i, text in
                Todo(content: text, status: i < done ? "completed" : i == done ? "in_progress" : "pending")
            }
    }

    static func sessions(_ store: SessionStore, _ usage: UsageStore, _ git: GitStatusStore, now: Date) {
        store.definedAgents = { _ in ["architect", "planner", "developer", "verifier"] }
        func e(_ name: String, _ id: String, ago: TimeInterval, tool: String? = nil, detail: String? = nil, agent: String? = nil,
               verdict: String? = nil, todos: [Todo]? = nil) {
            var event = HookEvent(timestamp: now - ago, sessionId: id, cwd: "/Users/demo/\(folder[id]!)", hookEventName: name,
                                  transcriptPath: nil, toolName: tool, toolDetail: detail, subagentType: agent, verdict: verdict,
                                  todos: todos)
            if name == "SessionStart" { event.pid = 999_999 }
            store.apply(event)
        }
        e("SessionStart", "s3", ago: 3900)
        e("PreToolUse", "s3", ago: 3800, tool: "Agent", agent: "architect")
        e("SubagentStop", "s3", ago: 3600, agent: "architect")
        e("PreToolUse", "s3", ago: 3590, tool: "Agent", agent: "planner")
        e("SubagentStop", "s3", ago: 3300, agent: "planner")
        e("Stop", "s3", ago: 300)
        e("SessionStart", "s2", ago: 2650)
        for (agent, from, to) in [("architect", 2600.0, 2480.0), ("planner", 2470, 2200), ("developer", 2190, 600)] {
            e("PreToolUse", "s2", ago: from, tool: "Agent", agent: agent)
            e("SubagentStop", "s2", ago: to, agent: agent)
        }
        e("PreToolUse", "s2", ago: 140, tool: "Agent", agent: "verifier")
        e("PreToolUse", "s2", ago: 6, tool: "Grep", detail: "def refund")
        e("SessionStart", "s1", ago: 1520)
        for (agent, from, to) in [("architect", 1500.0, 1380.0), ("planner", 1370, 1150)] {
            e("PreToolUse", "s1", ago: from, tool: "Agent", agent: agent)
            e("SubagentStop", "s1", ago: to, agent: agent)
        }
        e("PreToolUse", "s1", ago: 1140, tool: "Agent", agent: "developer")
        e("PostToolUse", "s1", ago: 40, tool: "TodoWrite", todos: todos(done: 3))
        e("PreToolUse", "s1", ago: 3, tool: "Bash", detail: "npm test -- cart")

        for (id, k) in [("s1", 1.0), ("s2", 1.6), ("s3", 0.5)] {
            usage.entries[id] = [UsageEntry(model: "claude-opus-5-5", timestamp: now - 120, tokens: TokenUsage(
                input: Int(60_000 * k), output: Int(38_000 * k), cacheRead: Int(3_400_000 * k), cacheWrite5m: Int(210_000 * k)))]
        }
        usage.contexts = ["s1": ContextUsage(tokens: 340_000, model: "claude-opus-5-5", at: now),
                          "s2": ContextUsage(tokens: 610_000, model: "claude-opus-5-5", at: now),
                          "s3": ContextUsage(tokens: 120_000, model: "claude-opus-5-5", at: now)]
        git.lookup = { _ in nil }
        git.info = ["/Users/demo/storefront": GitInfo(branch: "feature/checkout", changed: 7),
                    "/Users/demo/payments-api": GitInfo(branch: "fix/refund-rounding", changed: 3),
                    "/Users/demo/mobile-app": GitInfo(branch: "main", changed: 0)]
    }

    static func configChange(now: Date) -> ConfigChange {
        ConfigChange(at: Calendar.current.date(byAdding: .day, value: -4, to: Calendar.current.startOfDay(for: now))! + 8 * 3600,
                     files: [".claude/agents/planner.md"])
    }

    static func load(_ analytics: Analytics, store: AnalyticsStore, root: URL, prices: PriceTable, now: Date) async {
        guard let events = try? history(in: root, now: now) else { return }
        let defaults = UserDefaults(suiteName: "pitwall-demo")!
        defaults.removePersistentDomain(forName: "pitwall-demo")
        await store.importTranscripts(root: root.appending(path: "projects"), events: events, defaults: defaults, now: now)
        await store.ingestEvents(url: events)
        await analytics.reload()
        analytics.budget = await store.budget(prices: prices)
    }

    static func history(in root: URL, now: Date) throws -> URL {
        var seed: UInt64 = 42
        func r() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let iso = ISO8601DateFormatter()
        let today = Calendar.current.startOfDay(for: now)
        let projects = [("storefront", 1.0), ("payments-api", 0.75), ("mobile-app", 0.5), ("design-system", 0.3), ("infra", 0.18)]
        for (project, weight) in projects {
            var lines = ""
            for day in 0..<14 {
                let start = Calendar.current.date(byAdding: .day, value: -day, to: today)!
                let count = Int((60 + r() * 110) * weight * (day < 7 ? 1 : 0.85))
                for m in 0..<count {
                    var ts = start + 9 * 3600 + r() * 9 * 3600
                    if ts > now { ts = now - r() * 3 * 3600 }
                    let model = r() < 0.7 ? "claude-opus-5-5" : (r() < 0.7 ? "claude-sonnet-5-5" : "claude-haiku-5-5")
                    let read = Int(60_000 + r() * 160_000), write = Int(2_000 + r() * 8_000)
                    lines += #"{"type":"assistant","sessionId":"\#(project)-\#(day)","cwd":"/Users/demo/\#(project)","timestamp":"\#(iso.string(from: ts))","message":{"id":"\#(project)-\#(day)-\#(m)","model":"\#(model)","role":"assistant","usage":{"input_tokens":\#(Int(500 + r() * 3000)),"output_tokens":\#(Int(400 + r() * 2600)),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"cache_creation":{"ephemeral_5m_input_tokens":\#(write),"ephemeral_1h_input_tokens":0}}}}"# + "\n"
                }
            }
            let folder = root.appending(path: "projects/-Users-demo-\(project)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try lines.write(to: folder.appending(path: "\(project).jsonl"), atomically: true, encoding: .utf8)
        }

        var log = ""
        func ev(_ name: String, _ session: String, _ at: Date, tool: String? = nil, agent: String? = nil, verdict: String? = nil) {
            var o: [String: String] = ["timestamp": iso.string(from: at), "session_id": session, "cwd": "/Users/demo/storefront",
                                       "hook_event_name": name]
            o["tool_name"] = tool
            o["subagent_type"] = agent
            o["verdict"] = verdict
            log += String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) + "\n"
        }
        for day in (0..<7).reversed() {
            for k in 0..<3 {
                let session = "run-\(day)-\(k)"
                var at = Calendar.current.date(byAdding: .day, value: -day, to: today)! + 10 * 3600 + Double(k) * 7200
                for (gate, minutes) in [("architect", 2.0), ("planner", 3.5), ("developer", 14.0), ("verifier", 4.0)] {
                    let end = at + minutes * 60 * (0.6 + r() * 0.8)
                    guard end < now else { break }
                    ev("PreToolUse", session, at, tool: "Agent", agent: gate)
                    ev("SubagentStop", session, end, agent: gate, verdict: gate == "verifier" ? (r() < (end < configChange(now: now).at ? 0.4 : 0.15) ? "fail" : "pass") : nil)
                    let model = gate == "verifier" || (gate == "developer" && day < 4) ? "claude-sonnet-5-5" : "claude-opus-5-5"
                    try subagent(session: session, gate: gate, model: model, from: at, to: end, in: root, r: r)
                    at = end + 20
                }
            }
        }
        let url = root.appending(path: "events.jsonl")
        try log.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func subagent(session: String, gate: String, model: String, from: Date, to: Date, in root: URL,
                                 r: () -> Double) throws {
        let dir = root.appending(path: "projects/-Users-demo-storefront/\(session)/subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let scale: Double = ["architect": 0.5, "planner": 0.6, "developer": 1.6, "verifier": 0.7][gate] ?? 1
        var lines = ""
        for m in 0..<8 {
            let ts = iso.string(from: from + to.timeIntervalSince(from) * Double(m + 1) / 9)
            let input = Int(200 + r() * 800), output = Int((600 + r() * 1800) * scale)
            let read = Int((30_000 + r() * 60_000) * scale), write = Int((1_500 + r() * 4_000) * scale)
            let usage = #""usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"#
                + #""cache_creation_input_tokens":\#(write),"cache_creation":{"ephemeral_5m_input_tokens":\#(write),"ephemeral_1h_input_tokens":0}}"#
            lines += #"{"type":"assistant","sessionId":"\#(session)","cwd":"/Users/demo/storefront","timestamp":"\#(ts)","#
                + #""message":{"id":"\#(session)-\#(gate)-\#(m)","model":"\#(model)","role":"assistant",\#(usage)}}"# + "\n"
        }
        try lines.write(to: dir.appending(path: "agent-\(gate).jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"\#(gate)","finished":true}"#.write(to: dir.appending(path: "agent-\(gate).meta.json"), atomically: true, encoding: .utf8)
    }
}
