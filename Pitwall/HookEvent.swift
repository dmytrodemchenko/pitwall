import Foundation

struct HookEvent: Decodable, Equatable {
    let timestamp: Date
    let sessionId: String
    let cwd: String?
    let hookEventName: String
    let transcriptPath: String?
    let toolName: String?
    var toolDetail: String? = nil
    var subagentType: String?
    let verdict: String?
    var lastMessage: String? = nil
    var pid: Int32? = nil
    var tty: String? = nil
    var terminalApp: String? = nil
    var todos: [Todo]? = nil
    var task: TaskChange? = nil

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func parse(_ line: Data) -> HookEvent? {
        guard var e = try? decoder.decode(HookEvent.self, from: line) else { return nil }
        if e.subagentType == "" { e.subagentType = nil }
        return e
    }
}
