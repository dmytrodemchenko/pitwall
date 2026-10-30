import Foundation
import Observation

enum SessionStatus: Int, Comparable {
    case idle, running, waiting, failed

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct Session: Identifiable, Equatable {
    let id: String
    var project: String
    var folder: String?
    var transcriptPath: String?
    var startedAt: Date
    var lastEventAt: Date
    var activity: SessionStatus = .running
    var verifierFailed = false
    var verifierPassed = false
    var gate: String?
    var agents: [String] = []
    var defined: [String] = []
    var gateRuns: [String: GateRun] = [:]
    var action: ToolAction?
    var actionRunning = false
    var todos: [Todo] = []
    var isEnded = false
    var pid: Int32?
    var tty: String?
    var terminalApp: String?

    var status: SessionStatus { verifierFailed ? .failed : activity }
}

@Observable
final class SessionStore {
    static let timeout: TimeInterval = 30 * 60
    static let retention: TimeInterval = 24 * 3600

    private(set) var sessions: [String: Session] = [:]
    @ObservationIgnored var verifierPattern: () -> String = { Verifier.pattern() }
    @ObservationIgnored var definedAgents: (String?) -> [String] = { GateRun.defined(in: $0) }

    var activeSessions: [Session] {
        sessions.values.filter { !$0.isEnded }.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    var aggregateStatus: SessionStatus {
        activeSessions.map(\.status).max() ?? .idle
    }

    var recentSessions: [Session] {
        sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    var recentFolders: [String] {
        var seen = Set<String>()
        return recentSessions.compactMap(\.folder).filter { seen.insert($0).inserted }
    }

    var headline: Session? {
        activeSessions.max { $0.status < $1.status }
    }

    func apply(_ e: HookEvent) {
        var s = sessions[e.sessionId] ?? Session(id: e.sessionId, project: Self.projectName(e.cwd), folder: e.cwd,
                                                 startedAt: e.timestamp, lastEventAt: e.timestamp, defined: definedAgents(e.cwd))
        s.lastEventAt = max(s.lastEventAt, e.timestamp)
        s.transcriptPath = e.transcriptPath ?? s.transcriptPath
        s.isEnded = false

        switch e.hookEventName {
        case "SessionStart":
            s.activity = .running
            if let cwd = e.cwd {
                s.project = Self.projectName(cwd)
                if s.folder != cwd { s.defined = definedAgents(cwd) }
                s.folder = cwd
            }
        case "PostToolUse":
            s.activity = .running
            s.actionRunning = false
        case "SubagentStop":
            s.activity = .running
            if let agent = e.subagentType ?? s.gate, s.gateRuns[agent]?.end == nil {
                s.gateRuns[agent]?.end = e.timestamp
            }
        case "PreToolUse":
            s.activity = .running
            if let tool = e.toolName {
                s.action = ToolAction.describe(tool: tool, detail: e.toolDetail, subagent: e.subagentType, cwd: s.folder ?? e.cwd)
                s.actionRunning = true
            }
            if let agent = GateRun.working(e) {
                if !s.agents.contains(agent) { s.agents.append(agent) }
                if s.gateRuns[agent].map({ $0.end != nil }) ?? true {
                    s.gateRuns[agent] = GateRun(start: e.timestamp)
                    s.verifierPassed = false
                }
                s.gate = agent
            }
            if let agent = GateRun.handingBack(e) { s.gateRuns[agent]?.end = e.timestamp }
        case "Notification":
            s.activity = .waiting
        case "Stop":
            s.activity = .idle
            s.actionRunning = false
        case "SessionEnd":
            s.isEnded = true
        default:
            break
        }
        s.todos.apply(todos: e.todos, task: e.task)
        if let pid = e.pid {
            s.pid = pid
            s.tty = e.tty
            s.terminalApp = e.terminalApp ?? s.terminalApp
        }
        if e.hookEventName == "SubagentStop", e.subagentType == "verifier",
           let failed = Verifier.failed(message: e.lastMessage, verdict: e.verdict, pattern: verifierPattern()) {
            s.verifierFailed = failed
            s.verifierPassed = !failed
        }

        sessions[e.sessionId] = s
    }

    @discardableResult
    func expire(now: Date) -> [String] {
        var pruned: [String] = []
        for (id, s) in sessions {
            let quiet = now.timeIntervalSince(s.lastEventAt)
            if !s.isEnded, quiet > Self.timeout { sessions[id]?.isEnded = true }
            if quiet > Self.retention {
                sessions[id] = nil
                pruned.append(id)
            }
        }
        return pruned
    }

    static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
