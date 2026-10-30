import Foundation

struct Loop: Equatable {
    enum Kind: Equatable {
        case repeats(ToolAction)
        case edits(file: String)
        case verifierFails
    }

    let session: String
    let kind: Kind
    let agent: String?
    let count: Int
    let since: Date

    func message(project: String, cost: Double?, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
        let spent = cost.flatMap { $0 > 0 ? $0 : nil }.map { String(format: "$%.2f in %d min", $0, minutes) } ?? "\(minutes) min"
        switch kind {
        case .repeats(let action):
            return "\(project): \(agent ?? "Agent") is looping, \(spent)\nSame call \(count) times: \(action.text)"
        case .edits(let file):
            return "\(project): \(agent ?? "Agent") is looping, \(spent)\n\(count) edits to \(file)"
        case .verifierFails:
            return "\(project): developer ↔ verifier is looping, \(spent)\nThe verifier failed \(count) times in a row"
        }
    }
}

struct LoopDetector {
    static let window: TimeInterval = 10 * 60, repeats = 5, edits = 12, verifierFails = 3
    static let editTools: Set = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private struct Call {
        let at: Date
        let key: String
        let edit: Bool
    }

    private var calls: [String: [Call]] = [:]
    private var fails: [String: [Date]] = [:]

    mutating func observe(_ e: HookEvent, verifierFailed: Bool?) -> Loop? {
        let id = e.sessionId
        if let failed = verifierFailed {
            let streak = failed ? fails[id, default: []] + [e.timestamp] : []
            guard streak.count >= Self.verifierFails else {
                fails[id] = streak
                return nil
            }
            fails[id] = nil
            return Loop(session: id, kind: .verifierFails, agent: nil, count: streak.count, since: streak[0])
        }
        guard e.hookEventName == "PreToolUse", let tool = e.toolName,
              let detail = e.toolDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return nil }
        let edit = Self.editTools.contains(tool)
        let key = edit ? detail : "\(e.subagentType ?? "")|\(tool)|\(detail)"
        var list = calls[id, default: []].filter { e.timestamp.timeIntervalSince($0.at) < Self.window }
        list.append(Call(at: e.timestamp, key: key, edit: edit))
        let same = edit
            ? list.filter { $0.edit && $0.key == key }
            : list[((list.lastIndex(where: \.edit) ?? -1) + 1)...].filter { $0.key == key }
        guard same.count >= (edit ? Self.edits : Self.repeats) else {
            calls[id] = list
            return nil
        }
        calls[id] = nil
        let kind: Loop.Kind = edit ? .edits(file: (detail as NSString).lastPathComponent)
            : .repeats(ToolAction.describe(tool: tool, detail: detail, subagent: e.subagentType, cwd: e.cwd))
        return Loop(session: id, kind: kind, agent: e.subagentType.flatMap { $0.isEmpty ? nil : $0 },
                    count: same.count, since: same[0].at)
    }

    mutating func forget(_ session: String) {
        calls[session] = nil
        fails[session] = nil
    }
}
