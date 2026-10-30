import CryptoKit
import Foundation
import os

struct ConfigChange: Codable, Equatable, Sendable {
    let at: Date
    let files: [String]

    var label: String {
        files.map { $0.contains(".claude/agents/") ? (($0 as NSString).lastPathComponent as NSString).deletingPathExtension + " prompt" : $0 }
            .joined(separator: ", ")
    }

    static func git(in folder: String, since: Date, until: Date) -> [ConfigChange] {
        guard since < until else { return [] }
        let log = Git.run(["-C", folder, "log", "--since=\(Int(since.timeIntervalSince1970))", "--until=\(Int(until.timeIntervalSince1970))",
                           "--format=@%ct", "--name-only", "--", ".claude/agents", "CLAUDE.md"], timeout: 2) ?? ""
        return parse(log: log)
    }

    static func parse(log: String) -> [ConfigChange] {
        var changes: [ConfigChange] = []
        for line in log.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("@"), let t = TimeInterval(line.dropFirst()) {
                changes.append(ConfigChange(at: Date(timeIntervalSince1970: t), files: []))
            } else if let last = changes.popLast() {
                changes.append(ConfigChange(at: last.at, files: last.files + [line]))
            }
        }
        return changes.filter { !$0.files.isEmpty }
    }
}

struct ConfigHistory: Sendable {
    struct Folder: Codable {
        var since: Date
        var hashes: [String: String]
        var changes: [ConfigChange]
    }

    var url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-monitor/config-history.json")
    var home = FileManager.default.homeDirectoryForCurrentUser

    func files(in folder: String) -> [String: URL] {
        var files: [String: URL] = [:]
        for (base, prefix) in [(URL(filePath: folder), ""), (home, "~/")] {
            let agents = base.appending(path: ".claude/agents")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? [] where name.hasSuffix(".md") {
                files["\(prefix).claude/agents/\(name)"] = agents.appending(path: name)
            }
            let rules = prefix.isEmpty ? base.appending(path: "CLAUDE.md") : base.appending(path: ".claude/CLAUDE.md")
            if FileManager.default.fileExists(atPath: rules.path) { files[prefix.isEmpty ? "CLAUDE.md" : "~/.claude/CLAUDE.md"] = rules }
        }
        return files
    }

    func changes(in folder: String, since: Date, now: Date = Date()) -> [ConfigChange] {
        var all = (try? JSONDecoder().decode([String: Folder].self, from: Data(contentsOf: url))) ?? [:]
        let files = files(in: folder)
        let hashes = files.compactMapValues { (try? Data(contentsOf: $0)).map { SHA256.hash(data: $0).description } }
        var f = all[folder] ?? Folder(since: now, hashes: hashes, changes: [])
        let changed = Set(hashes.keys).union(f.hashes.keys).filter { hashes[$0] != f.hashes[$0] }.sorted()
        let stale = f.changes.contains { $0.at < now - AnalyticsStore.history }
        if all[folder] == nil || !changed.isEmpty || stale {
            if !changed.isEmpty {
                let modified = changed.compactMap { files[$0].flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } }
                f.changes.append(ConfigChange(at: min(modified.max() ?? now, now), files: changed))
                f.hashes = hashes
            }
            f.changes.removeAll { $0.at < now - AnalyticsStore.history }
            all[folder] = f
            save(all)
        }
        return ConfigChange.git(in: folder, since: since, until: f.since) + f.changes.filter { $0.at >= since }
    }

    private func save(_ all: [String: Folder]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Logger.app.error("config history \(url.path, privacy: .private) not saved: \(String(describing: error), privacy: .public)")
        }
    }
}

struct ConfigImpact: Identifiable, Equatable {
    struct Side: Equatable {
        var runs = 0, failures = 0
        var rate: Double? { runs == 0 ? nil : Double(failures) / Double(runs) }
    }

    static let minRuns = 3

    let project: String
    let change: ConfigChange
    let before: Side
    let after: Side

    var id: String { "\(project)|\(change.at.timeIntervalSince1970)" }
    var isMeasured: Bool { before.runs >= Self.minRuns && after.runs >= Self.minRuns }

    static func compare(changes: [ConfigChange], runs: [GateRunItem], project: String, pattern: String) -> [ConfigImpact] {
        let failed = runs.map { ($0.end, Verifier.failed(message: $0.lastMessage, verdict: $0.verdict, pattern: pattern) == true) }
        func side(_ from: Date, _ to: Date) -> Side {
            let r = failed.filter { $0.0 >= from && $0.0 < to }
            return Side(runs: r.count, failures: r.filter(\.1).count)
        }
        var merged: [ConfigChange] = []
        for c in changes.sorted(by: { $0.at < $1.at }) {
            if let last = merged.last, side(last.at, c.at).runs == 0 {
                merged[merged.count - 1] = ConfigChange(at: c.at, files: last.files + c.files.filter { !last.files.contains($0) })
            } else {
                merged.append(c)
            }
        }
        let changes = merged
        return changes.indices.map { i in
            ConfigImpact(project: project, change: changes[i],
                         before: side(i > 0 ? changes[i - 1].at : .distantPast, changes[i].at),
                         after: side(changes[i].at, i + 1 < changes.count ? changes[i + 1].at : .distantFuture))
        }
    }
}
