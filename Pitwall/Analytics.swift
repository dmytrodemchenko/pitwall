import Foundation
import Observation
import os
@preconcurrency import SwiftData

@Model
final class UsageRow {
    @Attribute(.unique) var messageID: String
    var timestamp: Date
    var project: String
    var session: String
    var model: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var agent: String?

    init(_ r: UsageRecord, project: String) {
        messageID = r.messageID
        timestamp = r.entry.timestamp
        self.project = project
        session = r.session ?? ""
        model = r.entry.model
        let t = r.entry.tokens
        input = t.input
        output = t.output
        cacheRead = t.cacheRead
        cacheWrite5m = t.cacheWrite5m
        cacheWrite1h = t.cacheWrite1h
        agent = r.agent
    }

    var item: UsageItem {
        UsageItem(project: project, session: session, entry: UsageEntry(
            model: model, timestamp: timestamp,
            tokens: TokenUsage(input: input, output: output, cacheRead: cacheRead,
                               cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h)), agent: agent)
    }
}

@Model
final class GateRunRow {
    @Attribute(.unique) var key: String
    var session: String
    var gate: String
    var start: Date
    var end: Date
    var lastMessage: String?
    var verdict: String?
    var folder: String?

    init(_ r: GateRunItem) {
        key = "\(r.session)|\(r.gate)|\(r.start.timeIntervalSince1970)"
        session = r.session
        gate = r.gate
        start = r.start
        end = r.end
        lastMessage = r.lastMessage
        verdict = r.verdict
        folder = r.folder
    }

    var item: GateRunItem {
        GateRunItem(session: session, gate: gate, start: start, end: end, lastMessage: lastMessage, verdict: verdict, folder: folder)
    }
}

struct GateRunItem: Equatable {
    let session: String
    let gate: String
    let start: Date
    let end: Date
    var lastMessage: String? = nil
    var verdict: String? = nil
    var folder: String? = nil

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

extension GateRunItem {
    private struct Meta: Decodable {
        let agentType: String?
        let finished: Bool?
    }

    static func agentType(transcript url: URL) -> String? {
        let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
        return (try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: meta)))?.agentType.flatMap { $0.isEmpty ? nil : $0 }
    }

    private struct Line: Decodable {
        struct Message: Decodable {
            struct Block: Decodable {
                let type: String?
                let text: String?
            }

            let blocks: [Block]

            enum CodingKeys: String, CodingKey { case content }

            init(from decoder: Decoder) throws {
                blocks = (try? decoder.container(keyedBy: CodingKeys.self).decode([Block].self, forKey: .content)) ?? []
            }
        }

        let timestamp: String?
        let cwd: String?
        let type: String?
        let message: Message?
    }

    static func subagent(transcript url: URL) -> GateRunItem? {
        let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
        guard let m = try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: meta)),
              let gate = m.agentType, !gate.isEmpty, m.finished != false,
              let data = try? Data(contentsOf: url) else { return nil }
        let iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var start: Date?, end: Date?, folder: String?, last: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let l = try? JSONDecoder().decode(Line.self, from: line),
                  let ts = l.timestamp.flatMap({ fractional.date(from: $0) ?? iso.date(from: $0) }) else { continue }
            start = start ?? ts
            end = ts
            folder = folder ?? l.cwd
            let text = (l.type == "assistant" ? l.message?.blocks ?? [] : []).compactMap { $0.type == "text" ? $0.text : nil }
            if !text.isEmpty { last = text.joined(separator: "\n") }
        }
        guard let start, let end else { return nil }
        let session = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return GateRunItem(session: session, gate: gate, start: start, end: end,
                           lastMessage: gate == "verifier" ? last.map { String($0.suffix(2000)) } : nil, folder: folder)
    }
}

struct GateRunBuilder {
    private var open: [String: GateRun] = [:]
    private var last: [String: String] = [:]

    mutating func apply(_ e: HookEvent) -> GateRunItem? {
        if let agent = GateRun.working(e) {
            let key = "\(e.sessionId)|\(agent)"
            if open[key]?.end != nil || open[key] == nil { open[key] = GateRun(start: e.timestamp) }
            last[e.sessionId] = agent
            if let agent = GateRun.handingBack(e) {
                if agent == "verifier" { open[key]?.end = e.timestamp; return nil }
                return close(key, session: e.sessionId, agent: agent, at: e.timestamp, e)
            }
        }
        guard e.hookEventName == "SubagentStop", let agent = e.subagentType ?? last[e.sessionId] else { return nil }
        return close("\(e.sessionId)|\(agent)", session: e.sessionId, agent: agent, at: e.timestamp, e)
    }

    private mutating func close(_ key: String, session: String, agent: String, at: Date, _ e: HookEvent) -> GateRunItem? {
        guard let run = open.removeValue(forKey: key) else { return nil }
        return GateRunItem(session: session, gate: agent, start: run.start, end: run.end ?? at,
                           lastMessage: agent == "verifier" ? e.lastMessage : nil,
                           verdict: agent == "verifier" ? e.verdict : nil, folder: e.cwd)
    }
}

struct PipelineReport {
    struct Gate: Identifiable {
        let name: String
        let runs: Int
        let average: TimeInterval
        let median: TimeInterval
        let total: TimeInterval
        var id: String { name }
        var isPipeline: Bool { GateRun.isPipeline(name) }
    }

    let gates: [Gate]
    let verifierRuns: Int
    let verifierFailures: Int
    let slowest: String?

    var failureRate: Double? { verifierRuns == 0 ? nil : Double(verifierFailures) / Double(verifierRuns) }

    init(runs: [GateRunItem], pattern: String, now: Date, calendar: Calendar = .current) {
        let from = CostReport.days(ending: now, calendar: calendar)[0]
        let week = runs.filter { $0.end >= from && $0.end <= now }
        let byGate = Dictionary(grouping: week, by: \.gate)
        var seen = Set<String>()
        let order = week.sorted { $0.start < $1.start }.map(\.gate).filter { seen.insert($0).inserted }
        let gates = order.compactMap { name -> Gate? in
            guard let runs = byGate[name], !runs.isEmpty else { return nil }
            let d = runs.map(\.duration).sorted()
            let median = d.count.isMultiple(of: 2) ? (d[d.count / 2 - 1] + d[d.count / 2]) / 2 : d[d.count / 2]
            let total = d.reduce(0, +)
            return Gate(name: name, runs: d.count, average: total / Double(d.count), median: median, total: total)
        }
        self.gates = gates
        let verifier = byGate["verifier"] ?? []
        verifierRuns = verifier.count
        verifierFailures = verifier.filter {
            Verifier.failed(message: $0.lastMessage, verdict: $0.verdict, pattern: pattern) == true
        }.count
        slowest = gates.filter(\.isPipeline).max { $0.total < $1.total }?.name
    }
}

struct UsageItem {
    let project: String
    let session: String
    let entry: UsageEntry
    var agent: String? = nil
}

actor AnalyticsStore {
    static let importedKey = "analyticsImportedAt", backfilledKey = "analyticsBackfilledBefore", agentsKey = "analyticsAgentsTagged"
    static let history: TimeInterval = 30 * 86400

    private let container: ModelContainer
    private lazy var context = ModelContext(container)
    private var readers: [String: JSONLReader<UsageRecord>] = [:]
    private var events: JSONLReader<HookEvent>?
    private var gateRuns = GateRunBuilder()
    private var projects: [String: String] = [:]
    private var agents: [String: String] = [:]
    private(set) var saveError: String?
    private let save: @Sendable (ModelContext) throws -> Void
    private let configChanges: @Sendable (String, Date) -> [ConfigChange]

    init(container: ModelContainer, save: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
         configChanges: @escaping @Sendable (String, Date) -> [ConfigChange] = { ConfigHistory().changes(in: $0, since: $1) }) {
        self.container = container
        self.save = save
        self.configChanges = configChanges
    }

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: UsageRow.self, GateRunRow.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let dir = URL.applicationSupportDirectory.appending(path: "ClaudeMonitor")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let container = try ModelContainer(for: UsageRow.self, GateRunRow.self,
                                           configurations: ModelConfiguration(url: dir.appending(path: "analytics.store")))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appending(path: name).path)
        }
        return container
    }

    func importTranscripts(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects"),
                           events: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-monitor/events.jsonl"),
                           defaults: UserDefaults = .standard, now: Date = Date()) {
        let oldest = now.addingTimeInterval(-Self.history)
        let empty = ((try? context.fetchCount(FetchDescriptor<UsageRow>())) ?? 0) == 0
        let since = empty ? oldest : max(defaults.object(forKey: Self.importedKey) as? Date ?? oldest, oldest)
        let all = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        let untagged = defaults.bool(forKey: Self.agentsKey) ? [] : all.filter { $0.1 >= oldest && $0.0.path.contains("/subagents/") }
        ingest((all.filter { $0.1 >= since } + untagged).map(\.0), oldest: oldest)
        defaults.set(true, forKey: Self.agentsKey)
        let logStart = firstEvent(in: events) ?? .distantFuture
        if empty || defaults.object(forKey: Self.backfilledKey) as? Date != logStart {
            for (url, modified) in all where modified >= oldest && url.path.contains("/subagents/") {
                guard let run = GateRunItem.subagent(transcript: url), run.end < logStart, run.end >= oldest else { continue }
                context.insert(GateRunRow(run))
            }
            commit()
            defaults.set(logStart, forKey: Self.backfilledKey)
        }
        defaults.set(now, forKey: Self.importedKey)
    }

    func ingest(transcript: String) {
        let main = URL(fileURLWithPath: transcript)
        let dir = main.deletingPathExtension().appending(path: "subagents")
        let subagents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        ingest([main] + subagents.filter { $0.pathExtension == "jsonl" }, oldest: Date().addingTimeInterval(-Self.history))
    }

    func ingest(_ files: [URL], oldest: Date) {
        var batch = Set<String>()
        for url in files.sorted(by: { !$0.path.contains("/subagents/") && $1.path.contains("/subagents/") }) {
            let key = url.resolvingSymlinksInPath().path
            let reader = readers[key] ?? JSONLReader(url: url, parse: UsageRecord.parse)
            readers[key] = reader
            agents[key] = url.path.contains("/subagents/") ? agents[key] ?? GateRunItem.agentType(transcript: url) : nil
            for var record in reader.readNew() {
                record.agent = agents[key]
                let session = record.session ?? url.path
                let project = projects[session] ?? SessionStore.projectName(record.cwd)
                projects[session] = project
                if record.entry.timestamp >= oldest, batch.insert(record.messageID).inserted { context.insert(UsageRow(record, project: project)) }
            }
        }
        commit()
    }

    private func firstEvent(in url: URL) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        return head.split(separator: UInt8(ascii: "\n")).lazy.compactMap { HookEvent.parse(Data($0)) }.first?.timestamp
    }

    func ingestEvents(url: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-monitor/events.jsonl")) {
        let reader = events ?? JSONLReader(url: url, parse: HookEvent.parse)
        events = reader
        for e in reader.readNew() {
            if let run = gateRuns.apply(e) { context.insert(GateRunRow(run)) }
        }
        commit()
    }

    func commit(now: Date = Date()) {
        let cutoff = now - Self.history
        do {
            try save(context)
            try context.delete(model: UsageRow.self, where: #Predicate { $0.timestamp < cutoff })
            try context.delete(model: GateRunRow.self, where: #Predicate { $0.end < cutoff })
            try save(context)
            saveError = nil
        } catch {
            Logger.app.error("analytics save failed: \(String(describing: error), privacy: .public)")
            saveError = error.localizedDescription
        }
    }

    func gateRuns(since: Date) -> [GateRunItem] {
        let rows = (try? context.fetch(FetchDescriptor<GateRunRow>(predicate: #Predicate { $0.end >= since }))) ?? []
        return rows.map(\.item)
    }

    func items(since: Date) -> [UsageItem] {
        let rows = (try? context.fetch(FetchDescriptor<UsageRow>(predicate: #Predicate { $0.timestamp >= since }))) ?? []
        return rows.map(\.item)
    }

    func costReport(prices: PriceTable, now: Date = Date()) -> CostReport {
        CostReport(items: items(since: CostReport.days(ending: now).first!), prices: prices, now: now)
    }

    func budget(prices: PriceTable, now: Date = Date()) -> BudgetStatus {
        let from = min(Calendar.current.startOfDay(for: now), now - BudgetSettings.window)
        return BudgetStatus(entries: items(since: from).map(\.entry), prices: prices, now: now)
    }

    func configImpacts(pattern: String, now: Date = Date()) -> [ConfigImpact] {
        let since = now - Self.history
        let runs = gateRuns(since: since).filter { $0.gate == "verifier" && $0.folder != nil }
        return Dictionary(grouping: runs) { $0.folder! }.flatMap { folder, runs in
            ConfigImpact.compare(changes: configChanges(folder, since), runs: runs, project: SessionStore.projectName(folder), pattern: pattern)
        }.sorted { $0.change.at > $1.change.at }
    }

    func modelAdvice(prices: PriceTable, pattern: String, now: Date = Date()) -> [ModelAdvice] {
        let from = CostReport.days(ending: now).first!
        return ModelAdvice.advise(items: items(since: from), runs: gateRuns(since: from), prices: prices, pattern: pattern)
    }

    func reports(prices: PriceTable, pattern: String, now: Date = Date()) -> (CostReport, CacheReport, PipelineReport) {
        let from = CostReport.days(ending: now).first!
        let week = items(since: from)
        return (CostReport(items: week, prices: prices, now: now), CacheReport(entries: week.map(\.entry), now: now),
                PipelineReport(runs: gateRuns(since: from), pattern: pattern, now: now))
    }
}

enum CacheRatio {
    static let warnKey = "cacheWarnPercent", defaultWarn = 50.0
    static let window: TimeInterval = 10 * 60

    static func of(_ t: TokenUsage) -> Double? {
        let all = t.cacheRead + t.cacheWrite5m + t.cacheWrite1h + t.input
        return all == 0 ? nil : Double(t.cacheRead) / Double(all)
    }

    static func of(_ entries: [UsageEntry]) -> Double? { of(entries.tokens) }

    static func recent(_ entries: [UsageEntry], now: Date, window: TimeInterval = window) -> Double? {
        guard let first = entries.map(\.timestamp).min(), now.timeIntervalSince(first) >= window else { return nil }
        return of(entries.filter { $0.timestamp > now.addingTimeInterval(-window) && $0.timestamp <= now })
    }

    static func isLow(_ entries: [UsageEntry], now: Date, percent: Double, window: TimeInterval = window) -> Bool {
        recent(entries, now: now, window: window).map { $0 * 100 < percent } ?? false
    }

    static func warnPercent(_ defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: warnKey) as? Double ?? defaultWarn
    }
}

struct CacheReport {
    struct Day: Identifiable {
        let day: Date
        let ratio: Double
        var id: Date { day }
    }

    let days: [Date]
    let points: [Day]
    let today: Double?

    init(entries: [UsageEntry], now: Date, calendar: Calendar = .current) {
        let days = CostReport.days(ending: now, calendar: calendar)
        self.days = days
        let byDay = Dictionary(grouping: entries.filter { $0.timestamp >= days[0] && $0.timestamp <= now }) {
            calendar.startOfDay(for: $0.timestamp)
        }
        let points = days.compactMap { day in byDay[day].flatMap(CacheRatio.of).map { Day(day: day, ratio: $0) } }
        self.points = points
        today = points.last { $0.day == days[6] }?.ratio
    }
}

struct CostReport {
    struct Bar: Identifiable {
        let day: Date
        let series: String
        let cost: Double
        var id: String { "\(day.timeIntervalSince1970)|\(series)" }
    }
    struct ProjectTotal: Identifiable {
        let project: String
        let cost: Double
        let tokens: Int
        var id: String { project }
    }

    static let other = "Other", top = 5

    let days: [Date]
    let series: [String]
    let bars: [Bar]
    let projects: [ProjectTotal]

    var total: Double { projects.reduce(0) { $0 + $1.cost } }

    static func days(ending now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }

    init(items: [UsageItem], prices: PriceTable, now: Date, calendar: Calendar = .current) {
        let days = Self.days(ending: now, calendar: calendar)
        self.days = days
        let week = items.filter { $0.entry.timestamp >= days[0] && $0.entry.timestamp <= now }
        let cost = { (i: UsageItem) in prices.price(for: i.entry.model)?.cost(i.entry.tokens) ?? 0 }

        projects = Dictionary(grouping: week, by: \.project)
            .map { ProjectTotal(project: $0, cost: $1.reduce(0) { $0 + cost($1) }, tokens: $1.map(\.entry).tokens.total) }
            .sorted { ($0.cost, $1.project) > ($1.cost, $0.project) }
        let top = Set(projects.prefix(Self.top).map(\.project))
        let series = projects.prefix(Self.top).map(\.project) + (projects.count > Self.top ? [Self.other] : [])
        self.series = series

        var sums: [Date: [String: Double]] = [:]
        for i in week {
            sums[calendar.startOfDay(for: i.entry.timestamp), default: [:]][top.contains(i.project) ? i.project : Self.other, default: 0] += cost(i)
        }
        bars = days.flatMap { day in
            series.compactMap { s in sums[day]?[s].map { Bar(day: day, series: s, cost: $0) } }
        }
    }

    func bars(on day: Date) -> [Bar] { bars.filter { $0.day == day } }
}

@MainActor @Observable
final class Analytics {
    var cost: CostReport?
    var cache: CacheReport?
    var pipeline: PipelineReport?
    var config: [ConfigImpact] = []
    var models: [ModelAdvice] = []
    var budget = BudgetStatus()
    var today: [UsageEntry] = []
    var importing = false
    var saveError: String?
    @ObservationIgnored let store: AnalyticsStore?
    @ObservationIgnored private let prices: PriceTable
    @ObservationIgnored let alerts: BudgetAlerts?
    @ObservationIgnored private var windowTimer: Timer?

    init(store: AnalyticsStore?, prices: PriceTable, alerts: BudgetAlerts? = nil) {
        self.store = store
        self.prices = prices
        self.alerts = alerts
    }

    func start() {
        guard let store else { return }
        importing = true
        Task {
            await store.ingestEvents()
            await store.importTranscripts()
            importing = false
            saveError = await store.saveError
            await reload()
            await refreshBudget(alert: false)
        }
    }

    func ingest(transcript: String) {
        guard let store else { return }
        Task {
            await store.ingest(transcript: transcript)
            saveError = await store.saveError
            await refreshBudget(alert: true)
        }
    }

    func ingestEvents() {
        guard let store else { return }
        Task {
            await store.ingestEvents()
            saveError = await store.saveError
        }
    }

    func refreshBudget(alert: Bool) async {
        guard let store else { return }
        let status = await store.budget(prices: prices)
        if status != budget { budget = status }
        let entries = await store.items(since: Calendar.current.startOfDay(for: Date())).map(\.entry).sorted { $0.timestamp < $1.timestamp }
        if entries != today { today = entries }
        if alert { alerts?.check(status) }
        windowTimer?.invalidate()
        if let at = status.windowFreesAt, at > Date() {
            windowTimer = Timer.scheduledTimer(withTimeInterval: at.timeIntervalSinceNow + 1, repeats: false) { [weak self] _ in
                Task { await self?.refreshBudget(alert: false) }
            }
        }
    }

    func reload() async {
        guard let store else { return }
        (cost, cache, pipeline) = await store.reports(prices: prices, pattern: Verifier.pattern())
        config = await store.configImpacts(pattern: Verifier.pattern())
        models = await store.modelAdvice(prices: prices, pattern: Verifier.pattern())
    }
}
