import Foundation
import Observation

struct TokenUsage: Equatable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite5m = 0, cacheWrite1h = 0

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    static func + (a: Self, b: Self) -> Self {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                   cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }
}

struct UsageEntry: Equatable {
    let model: String
    let timestamp: Date
    let tokens: TokenUsage
}

extension Sequence where Element == UsageEntry {
    var tokens: TokenUsage { reduce(TokenUsage()) { $0 + $1.tokens } }
}

struct UsageRecord {
    let messageID: String
    let entry: UsageEntry
    var cwd: String?
    var session: String?

    private struct Line: Decodable {
        let timestamp: Date
        let cwd: String?
        let sessionId: String?
        let message: Message
    }
    private struct Message: Decodable {
        let id: String
        let model: String?
        let usage: Usage
    }
    private struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheCreation: CacheCreation?
    }
    private struct CacheCreation: Decodable {
        let ephemeral5mInputTokens: Int?
        let ephemeral1hInputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case ephemeral5mInputTokens = "ephemeral5MInputTokens"
            case ephemeral1hInputTokens = "ephemeral1HInputTokens"
        }
    }

    private static let decoder: JSONDecoder = {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true), plain = Date.ISO8601FormatStyle()
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = (try? fractional.parse(s)) ?? (try? plain.parse(s)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: s))
            }
            return date
        }
        return d
    }()

    static func parse(_ line: Data) -> UsageRecord? {
        guard line.range(of: usageKey) != nil, let l = try? decoder.decode(Line.self, from: line) else { return nil }
        let u = l.message.usage
        let write1h = u.cacheCreation?.ephemeral1hInputTokens ?? 0
        let write5m = u.cacheCreation?.ephemeral5mInputTokens ?? ((u.cacheCreationInputTokens ?? 0) - write1h)
        let tokens = TokenUsage(input: u.inputTokens ?? 0, output: u.outputTokens ?? 0,
                                cacheRead: u.cacheReadInputTokens ?? 0, cacheWrite5m: write5m, cacheWrite1h: write1h)
        return UsageRecord(messageID: l.message.id,
                           entry: UsageEntry(model: l.message.model ?? "unknown", timestamp: l.timestamp, tokens: tokens),
                           cwd: l.cwd, session: l.sessionId)
    }

    private static let usageKey = Data(#""usage""#.utf8)
}

@MainActor @Observable
final class UsageStore {
    var entries: [String: [UsageEntry]] = [:]
    var contexts: [String: ContextUsage] = [:]
    @ObservationIgnored private let reader = TranscriptReader()

    func refresh(session: String, transcriptPath: String, done: @escaping @MainActor () -> Void = {}) {
        reader.read(session: session, transcriptPath: transcriptPath) { [weak self] new, latest in
            guard let self else { return }
            if !new.isEmpty { entries[session, default: []] += new }
            if let latest, latest.at >= contexts[session]?.at ?? .distantPast { contexts[session] = latest }
            done()
        }
    }

    func forget(_ session: String) {
        entries[session] = nil
        contexts[session] = nil
        reader.forget(session)
    }

    func entries(for session: String) -> [UsageEntry] { entries[session] ?? [] }

    func today(now: Date = Date()) -> [UsageEntry] {
        entries.values.flatMap { $0 }.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: now) }
    }
}

private final class TranscriptReader: @unchecked Sendable {
    private var readers: [String: JSONLReader<UsageRecord>] = [:]
    private var seen: [String: Set<String>] = [:]
    private var paths: [String: Set<String>] = [:]
    private let queue = DispatchQueue(label: "UsageStore", qos: .utility)

    func read(session: String, transcriptPath: String,
              done: @escaping @MainActor @Sendable ([UsageEntry], ContextUsage?) -> Void) {
        queue.async { [self] in
            let main = URL(fileURLWithPath: transcriptPath)
            let subagentDir = main.deletingPathExtension().appending(path: "subagents")
            let subagents = (try? FileManager.default.contentsOfDirectory(at: subagentDir, includingPropertiesForKeys: nil)) ?? []

            var new: [UsageEntry] = []
            var latest: ContextUsage?
            for url in [main] + subagents where url.pathExtension == "jsonl" {
                let reader = readers[url.path] ?? JSONLReader(url: url, parse: UsageRecord.parse)
                readers[url.path] = reader
                paths[session, default: []].insert(url.path)
                for record in reader.readNew() {
                    if seen[session, default: []].insert(record.messageID).inserted { new.append(record.entry) }
                    let context = ContextUsage(record.entry)
                    if url == main, context.tokens > 0, context.at >= latest?.at ?? .distantPast { latest = context }
                }
            }
            let result = (new, latest)
            DispatchQueue.main.async { done(result.0, result.1) }
        }
    }

    func forget(_ session: String) {
        queue.async { [self] in
            for path in paths.removeValue(forKey: session) ?? [] { readers[path] = nil }
            seen[session] = nil
        }
    }
}
