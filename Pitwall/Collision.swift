import Foundation

struct CollisionDetector {
    static let window: TimeInterval = 30 * 60

    private var edits: [String: [String: Date]] = [:]
    private var alerted = Set<String>()

    mutating func observe(_ e: HookEvent) -> (file: String, other: String)? {
        if e.hookEventName == "SessionEnd" {
            forget(e.sessionId)
            return nil
        }
        guard e.hookEventName == "PreToolUse", LoopDetector.editTools.contains(e.toolName ?? ""),
              let detail = e.toolDetail, !detail.isEmpty else { return nil }
        let path = ((detail.hasPrefix("/") ? detail : ((e.cwd ?? "/") as NSString).appendingPathComponent(detail)) as NSString)
            .standardizingPath
        var by = edits[path, default: [:]].filter { e.timestamp.timeIntervalSince($0.value) < Self.window }
        by[e.sessionId] = e.timestamp
        edits[path] = by
        guard let other = by.filter({ $0.key != e.sessionId }).max(by: { $0.value < $1.value })?.key,
              alerted.insert(([other, e.sessionId].sorted() + [path]).joined(separator: "|")).inserted else { return nil }
        return (path, other)
    }

    mutating func forget(_ session: String) {
        for path in edits.keys {
            edits[path]?[session] = nil
            if edits[path]?.isEmpty == true { edits[path] = nil }
        }
    }

    static func message(file: String, projects: (String, String)) -> String {
        let name = (file as NSString).lastPathComponent
        return projects.0 == projects.1
            ? "Two \(projects.0) sessions are editing \(name)"
            : "\(projects.0) and \(projects.1) are both editing \(name)"
    }
}
