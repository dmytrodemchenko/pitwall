import Foundation

struct GateRun: Equatable {
    var start: Date
    var end: Date?

    static let limitKey = "gateLimitMinutes", defaultLimitMinutes = 10.0

    static func working(_ e: HookEvent) -> String? {
        guard e.hookEventName == "PreToolUse", let agent = e.subagentType, !agent.isEmpty else { return nil }
        return agent
    }

    static func handingBack(_ e: HookEvent) -> String? { e.toolName == "SubagentHandback" ? working(e) : nil }

    static func isPipeline(_ agent: String) -> Bool { !builtIn.contains(agent) && !agent.contains(":") }

    static let builtIn: Set = ["general-purpose", "Explore", "Plan", "claude-code-guide", "statusline-setup",
                               "output-style-setup", "web-fetch"]

    static func defined(in folder: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let dirs = [folder.map { URL(filePath: $0).appending(path: ".claude/agents") }, home.appending(path: ".claude/agents")]
        let names = dirs.compactMap { $0 }.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
        }
        var seen = Set<String>()
        return names.filter { isPipeline($0) && seen.insert($0).inserted }
    }

    func duration(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m \(s % 60)s"
        default: return "\(s / 3600)h \(s % 3600 / 60)m"
        }
    }
}

enum Verifier {
    static let patternKey = "verifierFailPattern", defaultPattern = "VERDICT: FAIL"

    static func pattern(_ defaults: UserDefaults = .standard) -> String {
        let p = defaults.string(forKey: patternKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return p.isEmpty ? defaultPattern : p
    }

    static func isValid(_ pattern: String) -> Bool { (try? NSRegularExpression(pattern: pattern)) != nil }

    static func failed(message: String, pattern: String) -> Bool {
        let last = message.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) } ?? ""
        return last.range(of: pattern, options: isValid(pattern) ? [.regularExpression, .caseInsensitive] : .caseInsensitive) != nil
    }

    static func failed(message: String?, verdict: String?, pattern: String) -> Bool? {
        if let message { return failed(message: message, pattern: pattern) }
        return verdict.map { $0 == "fail" }
    }
}
