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
        try? replay(in: root.appending(path: "projects"), now: now)
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

    static func replay(in projects: URL, now: Date) throws {
        let storefront = Transcript(start: now - 40 * 60, cwd: "/Users/demo/storefront")
        let t = storefront, f = "/Users/demo/storefront/src/checkout/"
        try t.write([
            t.user(0, "Also update the changelog"),
            t.call(4, "u1", "Read", ["file_path": "/Users/demo/storefront/CHANGELOG.md"]), t.result(5, "u1", "## Unreleased"),
            t.user(40, "[Request interrupted by user]"),
            t.user(900, "The checkout total is wrong when a coupon and free shipping are combined. Find the bug, fix it, and add a test."),
            t.say(904, "a", "I'll look at how the total is computed first."),
            t.call(906, "t1", "Grep", ["pattern": "applyCoupon"]), t.result(907, "t1", "src/checkout/total.ts\nsrc/checkout/coupon.ts"),
            t.call(909, "t2", "Read", ["file_path": f + "total.ts"]), t.result(910, "t2", "export function total(cart) { … }"),
            t.call(912, "t3", "Read", ["file_path": f + "coupon.ts"]), t.result(913, "t3", "export function applyCoupon(…) { … }"),
            t.line(920, ["type": "system", "subtype": "api_error", "retryAttempt": 1, "maxRetries": 10, "error": ["message": "Overloaded"]]),
            t.call(941, "t4", "Edit", ["file_path": f + "total.ts"]), t.result(942, "t4", "String to replace not found in file.", error: true),
            t.call(948, "t5", "Edit", ["file_path": f + "total.ts"], output: 2400), t.result(949, "t5", "The file has been updated."),
            t.call(955, "t6", "Write", ["file_path": f + "total.test.ts"], output: 3100), t.result(956, "t6", "File created successfully."),
            t.call(960, "t7", "Bash", ["command": "npm test -- checkout"]), t.result(984, "t7", "Tests: 1 failed, 41 passed", error: true),
            t.call(990, "t8", "Edit", ["file_path": f + "total.ts"]), t.result(991, "t8", "The file has been updated."),
            t.call(994, "t9", "Agent", ["subagent_type": "verifier", "description": "Verify the checkout fix"]),
            t.result(1071, "t9", "VERDICT: PASS"),
            t.call(1075, "t10", "Bash", ["command": "rm src/checkout/total.old.ts"]), t.result(1076, "t10", ""),
            t.say(1080, "z", "Fixed. The coupon discount was applied after free shipping zeroed the shipping line, so the discount was taken twice. `total()` now applies coupons to the subtotal only, and `total.test.ts` covers the combined case. The verifier passed."),
        ], to: projects.appending(path: "-Users-demo-storefront/checkout.jsonl"), subagents: [
            ("verifier", "t9", [
                t.call(997, "v1", "Read", ["file_path": f + "total.ts"], output: 300), t.result(998, "v1", "…"),
                t.call(1001, "v2", "Bash", ["command": "npm test"], output: 300), t.result(1050, "v2", "Tests: 42 passed"),
                t.say(1068, "v3", "All 42 tests pass and the combined case is covered.\nVERDICT: PASS"),
            ]),
        ])

        let p = Transcript(start: now - 22 * 60, cwd: "/Users/demo/payments-api"), r = "/Users/demo/payments-api/refunds/"
        var developer = [p.call(8, "d1", "Read", ["file_path": r + "partial.py"], model: "claude-sonnet-5-5"), p.result(9, "d1", "…")]
        for i in 0..<5 {
            let at = 30 + Double(i) * 70
            developer += [p.call(at, "d\(i + 2)", "Bash", ["command": "pytest -q tests/refunds"], output: 1800, model: "claude-sonnet-5-5"),
                          p.result(at + 25, "d\(i + 2)", "FAILED tests/refunds/test_partial.py::test_rounds_half_even - assert 10.01 == 10.00",
                                   error: true)]
        }
        developer += [
            p.call(400, "d8", "Edit", ["file_path": r + "partial.py"], output: 2200, model: "claude-sonnet-5-5"),
            p.result(401, "d8", "The file has been updated."),
            p.call(410, "d9", "Bash", ["command": "pytest -q tests/refunds"], model: "claude-sonnet-5-5"), p.result(436, "d9", "18 passed"),
            p.say(440, "d10", "Partial refunds now round half to even, per line before summing. 18 tests pass.", model: "claude-sonnet-5-5"),
        ]
        try p.write([
            p.user(0, "Partial refunds are off by a cent on some orders. Find the rounding bug and fix it."),
            p.call(4, "p1", "Agent", ["subagent_type": "developer", "description": "Fix refund rounding"]),
            p.result(442, "p1", "Partial refunds now round half to even."),
            p.say(450, "p2", "Fixed: refunds rounded each line half-up and then summed, so two halves could add a cent. They now round half to even per line. The developer agent retried the same failing test five times before changing the code."),
        ], to: projects.appending(path: "-Users-demo-payments-api/refunds.jsonl"), subagents: [("developer", "p1", developer)])
    }

    private struct Transcript {
        let start: Date
        let cwd: String
        private let iso = ISO8601DateFormatter()

        init(start: Date, cwd: String) {
            self.start = start
            self.cwd = cwd
        }

        func line(_ s: Double, _ fields: [String: Any]) -> String {
            var d = fields
            d["timestamp"] = iso.string(from: start + s)
            d["cwd"] = cwd
            d["uuid"] = UUID().uuidString
            return String(decoding: (try? JSONSerialization.data(withJSONObject: d)) ?? Data(), as: UTF8.self)
        }

        func user(_ s: Double, _ text: String) -> String { line(s, ["type": "user", "message": ["role": "user", "content": text]]) }

        func call(_ s: Double, _ id: String, _ name: String, _ input: [String: Any], output: Int = 900,
                  model: String = "claude-opus-5-5") -> String {
            line(s, ["type": "assistant", "message": ["id": "m-\(id)", "model": model, "stop_reason": "tool_use",
                     "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
                     "usage": ["input_tokens": 40, "output_tokens": output, "cache_read_input_tokens": 60_000]]])
        }

        func say(_ s: Double, _ id: String, _ text: String, model: String = "claude-opus-5-5") -> String {
            line(s, ["type": "assistant", "message": ["id": "m-\(id)", "model": model, "stop_reason": "end_turn",
                     "content": [["type": "text", "text": text]],
                     "usage": ["input_tokens": 20, "output_tokens": 400, "cache_read_input_tokens": 60_000]]])
        }

        func result(_ s: Double, _ id: String, _ text: String, error: Bool = false) -> String {
            line(s, ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text,
                                                                                "is_error": error]]]])
        }

        func write(_ lines: [String], to url: URL, subagents: [(agent: String, toolUse: String, lines: [String])]) throws {
            let dir = url.deletingPathExtension().appending(path: "subagents")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            for (agent, toolUse, lines) in subagents {
                try lines.joined(separator: "\n").write(to: dir.appending(path: "agent-\(agent).jsonl"), atomically: true, encoding: .utf8)
                try #"{"agentType":"\#(agent)","toolUseId":"\#(toolUse)"}"#
                    .write(to: dir.appending(path: "agent-\(agent).meta.json"), atomically: true, encoding: .utf8)
            }
        }
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
