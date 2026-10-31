import Foundation

@MainActor
final class Monitor {
    let store = SessionStore()
    let usage = UsageStore()
    let git = GitStatusStore()
    static let fileChangingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Bash", "PowerShell"]
    let prices: PriceTable
    let contextWindows: ContextWindows
    var contextThresholds: () -> (warn: Double, alert: Double) = { ContextLevel.thresholds() }
    private var contextAlerted = Set<String>()
    private let reader: EventLogReader
    private let notify: (String) -> Void
    var isAwaitingPermission: (String) -> Bool = { _ in false }
    var onTranscript: (String) -> Void = { _ in }
    var onEvents: () -> Void = {}
    var onLoop: (Loop, String) -> Void = { _, _ in }
    private var loops = LoopDetector()
    private var collisions = CollisionDetector()
    private var cacheWarned: [String: Date] = [:]
    var cacheMinCost: () -> Double = { CacheExpiry.minCost() }
    var isEstimate: () -> Bool = { BudgetSettings.mode() == .subscription }
    private var watcher: EventLogWatcher?
    private var expiryTimer: Timer?

    init(dir: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-monitor"),
         notify: @escaping (String) -> Void) {
        let logURL = dir.appending(path: "events.jsonl")
        EventLogRotation.rotate(logURL)
        reader = EventLogReader(url: logURL)
        prices = PriceTable.load(userFile: dir.appending(path: "prices.json"),
                                 defaultFile: Bundle.main.url(forResource: "prices", withExtension: "json"))
        contextWindows = ConfigFile.load(userFile: dir.appending(path: "context.json"),
                                         defaultFile: Bundle.main.url(forResource: "context", withExtension: "json"),
                                         decode: ContextWindows.decode) ?? .standard
        self.notify = notify
        ingest(live: false)
        watcher = EventLogWatcher(url: logURL, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.ingest(live: true) }
        }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    private func ingest(live: Bool) {
        var touched = Set<String>()
        let events = reader.readNew()
        if live, !events.isEmpty { onEvents() }
        for e in events.map(store.resolve) {
            store.apply(e)
            touched.insert(e.sessionId)
            let verifierFailed = e.hookEventName == "SubagentStop" && e.subagentType == "verifier"
                ? Verifier.failed(message: e.lastMessage, verdict: e.verdict, pattern: store.verifierPattern()) : nil
            if let loop = loops.observe(e, verifierFailed: verifierFailed), live {
                let cost = prices.cost(of: usage.entries(for: e.sessionId).filter { $0.timestamp >= loop.since })
                onLoop(loop, loop.message(project: store.sessions[e.sessionId]?.project ?? "Claude", cost: cost, now: e.timestamp))
            }
            if let c = collisions.observe(e), live {
                let project = { (id: String) in self.store.sessions[id]?.project ?? "Claude" }
                notify(CollisionDetector.message(file: c.file, projects: (project(e.sessionId), project(c.other))))
            }
            if live, e.hookEventName == "PostToolUse", Self.fileChangingTools.contains(e.toolName ?? ""),
               let folder = store.sessions[e.sessionId]?.folder {
                git.refresh(folder)
            }
            if live, !(e.hookEventName == "Notification" && isAwaitingPermission(e.sessionId)),
               let message = Self.alert(for: e, project: store.sessions[e.sessionId]?.project ?? "Claude") {
                notify(message)
            }
        }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        for id in touched {
            if let s = store.sessions[id], s.lastEventAt >= startOfToday, let path = s.transcriptPath {
                usage.refresh(session: id, transcriptPath: path) { [weak self] in
                    self?.checkContext(id, project: s.project, live: live)
                }
                if live { onTranscript(path) }
                if !s.isEnded, let folder = s.folder, !git.hasChecked(folder) { git.refresh(folder) }
            }
        }
        expire()
    }

    private func expire() {
        for id in store.expire(now: Date()) {
            usage.forget(id)
            contextAlerted.remove(id)
            loops.forget(id)
            collisions.forget(id)
            cacheWarned[id] = nil
        }
        checkCaches(now: Date())
    }

    func checkCaches(now: Date) {
        let min = cacheMinCost()
        guard min > 0 else { return }
        for s in store.activeSessions where s.activity != .running {
            guard let context = usage.contexts[s.id], cacheWarned[s.id] != context.at else { continue }
            let ttl = CacheExpiry.ttl(usage.entries(for: s.id))
            let left = context.at.addingTimeInterval(ttl).timeIntervalSince(now)
            guard left > 0, left <= CacheExpiry.lead,
                  let extra = CacheExpiry.extraCost(context, ttl: ttl, prices: prices), extra >= min else { continue }
            cacheWarned[s.id] = context.at
            notify(CacheExpiry.message(project: s.project, left: left, extra: extra, estimate: isEstimate()))
        }
    }

    private func checkContext(_ id: String, project: String, live: Bool) {
        guard !contextAlerted.contains(id), let context = usage.contexts[id] else { return }
        let percent = context.percent(of: contextWindows.window(for: context.model))
        guard percent > contextThresholds().alert else { return }
        contextAlerted.insert(id)
        if live { notify("\(project): context \(Int(percent))% full") }
    }

    nonisolated static func alert(for e: HookEvent, project: String) -> String? {
        if e.hookEventName == "Notification" { return "\(project) needs your input" }
        if e.hookEventName == "SubagentStop", e.subagentType == "verifier",
           Verifier.failed(message: e.lastMessage, verdict: e.verdict, pattern: Verifier.pattern()) == true {
            return "\(project): verifier failed"
        }
        return nil
    }
}
