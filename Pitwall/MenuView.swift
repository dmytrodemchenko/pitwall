import SwiftUI

extension SessionStatus {
    var color: NSColor {
        switch self {
        case .running: NSColor(resource: .running)
        case .waiting: NSColor(resource: .waiting)
        case .failed: NSColor(resource: .failure)
        case .idle: NSColor(resource: .idle)
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }
}

@Observable
final class PopoverState {
    var openedAt: Date?
    var height: CGFloat = 0
    var tabFrames: [MenuView.Tab: CGRect] = [:]
}

extension EnvironmentValues {
    @Entry var demoHover: String?
    @Entry var spots: Spots?
}

@MainActor
final class Spots {
    var frames: [String: CGRect] = [:]
}

private struct Spot: ViewModifier {
    let id: String
    @Environment(\.spots) private var spots

    func body(content: Content) -> some View {
        if let spots {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(MenuView.space)) }) { spots.frames[id] = $0 }
        } else {
            content
        }
    }
}

extension Animation {
    static let card = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let tab = Animation.spring(response: 0.5, dampingFraction: 0.84)
}

struct MenuView: View {
    let store: SessionStore
    let usage: UsageStore
    let prices: PriceTable
    var notifier: Notifier?
    var actions: SessionActions?
    var contextWindows = ContextWindows.standard
    var git: GitStatusStore?
    var analytics: Analytics?
    @State private var tab = Tab.sessions
    @State private var heights: [Tab: CGFloat] = [:]
    @State private var top: CGFloat = 0
    @State private var bottom: CGFloat = 0
    private var wanted: CGFloat? { top > 0 ? top + (heights[tab] ?? 0) + bottom : nil }
    var popover: PopoverState?
    @State private var appearedAt: Date?
    private var openedAt: Date? { popover.map(\.openedAt) ?? appearedAt }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab { case sessions, analytics }
    nonisolated static let space = "menu"

    private var live: Bool { openedAt != nil && !reduceMotion }

    var body: some View {
        let sessions = store.activeSessions
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                MascotStage(state: MarkState(session: store.headline), openedAt: openedAt, reduceMotion: reduceMotion)
                TabSwitch(tab: $tab, reduceMotion: reduceMotion) { popover?.tabFrames[$0] = $1 }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                Header(store: store, entries: usage.today(), prices: prices)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                if let analytics {
                    BudgetRow(status: analytics.budget)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                Divider().opacity(0.5)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { top = $0 }
            pager(sessions)
            VStack(spacing: 0) {
                if notifier?.isBlocked == true { NotificationsOff() }
                Divider().opacity(0.5)
                Footer(store: store, actions: actions).padding(.horizontal, 10).padding(.vertical, 8)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { bottom = $0 }
        }
        .frame(width: 360)
        .frame(minHeight: 0, idealHeight: wanted, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .coordinateSpace(.named(Self.space))
        .onChange(of: wanted, initial: true) { popover?.height = wanted ?? 0 }
        .task(id: openedAt) { if openedAt != nil { await analytics?.refreshBudget(alert: false) } }
        .onAppear { appearedAt = Date() }
        .onDisappear { appearedAt = nil }
    }

    private func pager(_ sessions: [Session]) -> some View {
        ZStack(alignment: .topLeading) {
            page(.sessions) { cards(sessions) }
            if let analytics {
                page(.analytics) { AnalyticsView(analytics: analytics, active: tab == .analytics) }
            }
        }
        .frame(width: 360)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func page(_ value: Tab, @ViewBuilder _ content: () -> some View) -> some View {
        let active = tab == value
        let side: CGFloat = value == .sessions ? -1 : 1
        return ViewThatFits(in: .vertical) {
            content()
            ScrollView { content() }
        }
        .frame(width: 360)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { heights[value] = $0 }
        .scaleEffect(active || reduceMotion ? 1 : 0.9, anchor: .top)
        .blur(radius: active || reduceMotion ? 0 : 6)
        .opacity(active ? 1 : 0)
        .offset(x: active || reduceMotion ? 0 : side * 360)
        .allowsHitTesting(active)
        .accessibilityHidden(!active)
    }

    private func cards(_ sessions: [Session]) -> some View {
        VStack(spacing: 8) {
            if let error = actions?.errors[SessionActions.general] {
                ActionErrorRow(message: error) { actions?.errors[SessionActions.general] = nil }
            }
            if sessions.isEmpty {
                EmptyState().transition(.opacity)
            }
            ForEach(sessions) { s in
                SessionCard(session: s, entries: usage.entries(for: s.id), prices: prices, live: live && tab == .sessions, actions: actions,
                        context: usage.contexts[s.id], contextWindows: contextWindows,
                        git: s.folder.flatMap { git?.info[$0] })
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))))
            }
        }
        .padding(12)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .card, value: sessions.map(\.id))
    }
}


private struct TabSwitch: View {
    @Binding var tab: MenuView.Tab
    var reduceMotion: Bool
    var onFrame: (MenuView.Tab, CGRect) -> Void = { _, _ in }
    @State private var lead: CGFloat = 0
    @State private var trail: CGFloat = 1
    private let tabs: [(Text, MenuView.Tab)] = [(Text("Sessions"), .sessions), (Text("Analytics"), .analytics)]

    var body: some View {
        labels
            .foregroundStyle(.primary)
            .overlay { labels.foregroundStyle(Color(.onAccent)).mask { highlight } }
            .background { highlight.foregroundStyle(Color(.accent)).shadow(color: .black.opacity(0.2), radius: 2, y: 1) }
            .overlay { buttons }
            .padding(2)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { (lead, trail) = edges(tab) }
            .onChange(of: tab) { old, new in move(from: old, to: new) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.1) { title, _ in
                title
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .accessibilityHidden(true)
    }

    private var highlight: some View {
        GeometryReader { g in
            let w = g.size.width / CGFloat(tabs.count)
            RoundedRectangle(cornerRadius: 6)
                .frame(width: max(w * 0.5, (trail - lead) * w))
                .offset(x: lead * w)
        }
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.1) { title, value in
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .tab) { tab = value }
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(MenuView.space)) }) { onFrame(value, $0) }
                .accessibilityLabel(title)
                .accessibilityAddTraits(tab == value ? .isSelected : [])
            }
        }
    }

    private func edges(_ t: MenuView.Tab) -> (CGFloat, CGFloat) {
        let i = CGFloat(tabs.firstIndex { $0.1 == t } ?? 0)
        return (i, i + 1)
    }

    private func move(from old: MenuView.Tab, to new: MenuView.Tab) {
        let (l, t) = edges(new)
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.15)) { (lead, trail) = (l, t) }
            return
        }
        let ahead = Animation.spring(response: 0.3, dampingFraction: 0.7)
        let behind = Animation.spring(response: 0.5, dampingFraction: 0.62).delay(0.04)
        let right = edges(new).0 > edges(old).0
        withAnimation(right ? ahead : behind) { trail = t }
        withAnimation(right ? behind : ahead) { lead = l }
    }
}


private struct Header: View {
    let store: SessionStore
    let entries: [UsageEntry]
    let prices: PriceTable
    @AppStorage(BudgetSettings.modeKey) private var mode = BillingMode.api

    var body: some View {
        let cost = prices.cost(of: entries)
        let tokens = entries.tokens.total
        let subscription = mode == .subscription
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pitwall").font(.headline)
                SessionCount(sessions: store.activeSessions)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageText.cost(cost, estimate: subscription))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText(value: cost ?? 0))
                Text(subscription ? "API-equivalent · \(UsageText.tokens(tokens)) tokens today" : "\(UsageText.tokens(tokens)) tokens today")
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(tokens)))
            }
            .monospacedDigit()
            .help(subscription ? "What today's tokens would cost at API prices. A subscription doesn't bill per token." : "")
            .animation(.snappy, value: tokens)
            .accessibilityElement(children: .combine)
        }
    }

}

struct BudgetRow: View {
    let status: BudgetStatus
    @AppStorage(BudgetSettings.modeKey) private var mode = BillingMode.api
    @AppStorage(BudgetSettings.dailyBudgetKey) private var budget = 0.0
    @AppStorage(BudgetSettings.windowLimitKey) private var limit = 0

    var body: some View {
        switch mode {
        case .api where budget > 0:
            row(icon: "dollarsign.circle", fraction: status.costToday / budget,
                text: "\(UsageText.cost(status.costToday)) of \(UsageText.cost(budget)) today", detail: nil)
        case .subscription where limit > 0:
            row(icon: "hourglass", fraction: Double(status.windowTokens) / Double(limit),
                text: "\(UsageText.tokens(status.windowTokens)) of \(UsageText.tokens(limit)) · 5 h", detail: status.windowFreesAt)
        default:
            EmptyView()
        }
    }

    private func row(icon: String, fraction: Double, text: String, detail freesAt: Date?) -> some View {
        let color: Color = fraction >= 1 ? Color(.failure) : fraction >= 0.8 ? Color(.waiting) : Color(.accent)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).imageScale(.small)
                Text(text).monospacedDigit().contentTransition(.numericText(value: fraction))
                if mode == .subscription {
                    Text("estimate")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.primary.opacity(0.08), in: Capsule())
                }
                Spacer(minLength: 4)
                Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(fraction >= 0.8 ? color : .secondary)
            }
            ThinBar(fraction: fraction, color: color)
            if let freesAt {
                TimelineView(.everyMinute) { ctx in
                    Text("Oldest usage leaves the window in \(Self.remaining(freesAt.timeIntervalSince(ctx.date)))")
                }
                .font(.system(size: 10))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.snappy, value: fraction)
        .help(mode == .api
              ? "Cost today against your daily budget (Settings). Notifications at 80% and 100%."
              : "Input, output and cache-write tokens in the last 5 hours against the limit you set in Settings. "
                + "An estimate: cache reads aren't counted, and Anthropic doesn't publish exact limits.")
        .accessibilityElement(children: .combine)
    }

    static func remaining(_ s: TimeInterval) -> String {
        let m = max(0, Int(s / 60))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

private struct SessionCount: View {
    let sessions: [Session]

    var body: some View {
        let status = sessions.map(\.status).max() ?? .idle
        HStack(spacing: 5) {
            Circle().fill(Color(nsColor: status.color)).frame(width: 6, height: 6)
            if sessions.isEmpty {
                Text("No active sessions")
            } else {
                Text("\(sessions.count) sessions").contentTransition(.numericText(value: Double(sessions.count)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .animation(.snappy, value: sessions.count)
        .animation(.snappy, value: status)
        .help(sessions.isEmpty ? "" : "Most urgent: \(status.label)")
    }
}


struct SessionCard: View {
    let session: Session
    let entries: [UsageEntry]
    let prices: PriceTable
    let live: Bool
    var actions: SessionActions?
    var context: ContextUsage?
    var contextWindows = ContextWindows.standard
    var git: GitInfo?
    @State private var hovering = false
    @Environment(\.demoHover) private var demoHover
    private var hover: Bool { hovering || demoHover?.hasPrefix(session.id + "/") == true }
    @AppStorage(CacheRatio.warnKey) private var cacheWarn = CacheRatio.defaultWarn
    @AppStorage(BudgetSettings.modeKey) private var mode = BillingMode.api

    var body: some View {
        let tint = Color(nsColor: session.status.color)
        let active = session.status == .running || session.status == .waiting
        let recent = active ? CacheRatio.recent(entries, now: Date()) : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.project).font(.system(.body, weight: .semibold)).lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    CardButton(id: session.id + "/resume", icon: "arrow.uturn.backward", help: "Resume in a new tab") { actions?.resume(session) }
                    if session.pid != nil {
                        CardButton(id: session.id + "/stop", icon: "stop.fill", help: "Stop this session (asks first)") { actions?.stop(session) }
                    }
                }
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                .accessibilityHidden(true)
                StatusBadge(status: session.status)
            }
            HStack(spacing: 6) {
                Image(systemName: "clock").imageScale(.small)
                Text(session.startedAt, style: .timer).monospacedDigit()
                Spacer(minLength: 8)
                if let recent, recent * 100 < cacheWarn {
                    Label("Cache \(Int((recent * 100).rounded()))%", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(.waiting))
                        .help("Cache hit ratio below \(Int(cacheWarn))% for the last 10 minutes: most input is being re-sent "
                              + "instead of read from the cache, which costs more. Threshold in Settings.")
                        .accessibilityLabel("Warning: cache hit ratio \(Int(recent * 100)) percent")
                        .transition(.opacity)
                }
                Text("\(UsageText.tokens(entries.tokens.total)) tok · \(UsageText.cost(prices.cost(of: entries), estimate: mode == .subscription))")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: entries.count)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let action = session.action {
                ActionLine(action: action, running: session.actionRunning)
            }
            if !PipelineTrack.agents(session).isEmpty {
                PipelineTrack(session: session, live: live)
            }
            if !session.todos.isEmpty {
                TodoRow(todos: session.todos)
            }
            if let context {
                ContextRow(context: context, window: contextWindows.window(for: context.model))
            }
            if let git {
                GitRow(git: git, folder: session.folder)
            }
            if let error = actions?.errors[session.id] {
                ActionErrorRow(message: error) { actions?.errors[session.id] = nil }
            }
        }
        .padding(12)
        .background(.primary.opacity(hover ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { actions?.openTerminal(session) }
        .help((CacheRatio.of(entries).map { "Cache hit ratio: \(Int(($0 * 100).rounded()))%\n" } ?? "")
              + "Click to bring this session's terminal to the front")
        .contextMenu {
            Button("Open in Terminal", systemImage: "terminal") { actions?.openTerminal(session) }
            Button("Open in IDE", systemImage: "chevron.left.forwardslash.chevron.right") { actions?.openIDE(session) }
            Divider()
            if let folder = session.folder {
                Button("New Session Here", systemImage: "plus") { actions?.newSession(in: folder, errorKey: session.id) }
            }
            Button("Resume in New Tab", systemImage: "arrow.uturn.backward") { actions?.resume(session) }
            Divider()
            Button("Stop…", systemImage: "stop.fill") { actions?.stop(session) }
                .disabled(session.pid == nil)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open in Terminal") { actions?.openTerminal(session) }
        .accessibilityAction(named: "Open in IDE") { actions?.openIDE(session) }
        .accessibilityAction(named: "Resume in New Tab") { actions?.resume(session) }
        .accessibilityAction(named: "Stop") { actions?.stop(session) }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(session.status == .running || session.status == .idle ? 0.12 : 0.45)))
        .animation(.card, value: session.status)
    }
}

private struct TodoRow: View {
    let todos: [Todo]

    var body: some View {
        let done = todos.completed, total = todos.count
        HStack(spacing: 8) {
            Image(systemName: "checklist").imageScale(.small)
            Text("\(done)/\(total) tasks")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(done)))
                .fixedSize()
            ThinBar(fraction: Double(done) / Double(max(total, 1)), color: Color(.accent))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.snappy, value: done)
        .animation(.snappy, value: total)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) tasks done. \(tooltip)")
    }

    private var tooltip: String {
        if let current = todos.inProgress { return "In progress: \(current.content)" }
        if let next = todos.first(where: { $0.status != "completed" }) { return "Next: \(next.content)" }
        return "All tasks done"
    }
}

private struct ContextRow: View {
    let context: ContextUsage
    let window: Int
    @AppStorage(ContextLevel.warnKey) private var warn = ContextLevel.defaultWarn
    @AppStorage(ContextLevel.alertKey) private var alert = ContextLevel.defaultAlert

    var body: some View {
        let percent = context.percent(of: window)
        let level = ContextLevel(percent: percent, warn: warn, alert: alert)
        let color: Color = switch level {
        case .normal: Color(.accent)
        case .warning: Color(.waiting)
        case .critical: Color(.failure)
        }
        HStack(spacing: 8) {
            Image(systemName: "brain").imageScale(.small)
            Text("Context").fixedSize()
            ThinBar(fraction: percent / 100, color: color)
            Text(percent / 100, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(level == .normal ? .secondary : color)
                .contentTransition(.numericText(value: percent))
                .frame(minWidth: 30, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.snappy, value: Int(percent))
        .help("\(UsageText.tokens(context.tokens)) of \(UsageText.tokens(window)) tokens · \(context.model)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(Int(percent.rounded())) percent full")
    }
}

private struct GitRow: View {
    let git: GitInfo
    let folder: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").imageScale(.small)
            Text(git.branch).lineLimit(1).truncationMode(.middle)
            Text("·")
            Text(git.changed == 0 ? "no changes" : "\(git.changed) changed")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(git.changed)))
                .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: git)
        .help(folder.map { "\(git.summary) in \($0)" } ?? git.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Git: branch \(git.branch), \(git.changed) changed files")
    }
}

struct ThinBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(color).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct ActionLine: View {
    let action: ToolAction
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: running ? "bolt.fill" : "checkmark")
                .imageScale(.small)
                .foregroundStyle(running ? Color(.accent) : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(action.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(running ? .primary : .secondary)
                .contentTransition(.opacity)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(action.full)
        .animation(.snappy, value: action)
        .animation(.snappy, value: running)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((running ? "Now: " : "Last: ") + action.full)
    }
}

private struct ActionErrorRow: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.failure))
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss error")
        }
        .font(.caption)
        .padding(8)
        .background(Color(.failure).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .transition(.opacity)
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        let tint = Color(nsColor: status.color)
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(status.label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label)")
    }
}


struct PipelineTrack: View {
    let session: Session
    let live: Bool
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum NodeState { case pending, done, current, failed }

    nonisolated static func agents(_ session: Session) -> [String] {
        let ran = session.agents.filter(GateRun.isPipeline)
        return Array((ran + session.defined.filter { !ran.contains($0) }).prefix(5))
    }

    private var agents: [String] { Self.agents(session) }
    private var current: Int? { session.gate.flatMap(agents.firstIndex(of:)) }
    private var reached: Int? { agents.lastIndex { session.gateRuns[$0] != nil } }

    private func state(_ gate: String) -> NodeState {
        if gate == "verifier" && session.verifierFailed { return .failed }
        guard let run = session.gateRuns[gate] else { return .pending }
        return run.end == nil ? .current : .done
    }

    var body: some View {
        let accent = Color(.accent)
        let count = agents.count
        let working = current.map { state(agents[$0]) == .current } ?? false
        ZStack(alignment: .top) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live || session.status != .running || !working)) { ctx in
                Canvas { g, size in
                    let x = { (i: Int) in size.width * (CGFloat(i) + 0.5) / CGFloat(count) }
                    let y: CGFloat = 8
                    var base = Path(); base.move(to: CGPoint(x: x(0), y: y)); base.addLine(to: CGPoint(x: x(count - 1), y: y))
                    g.stroke(base, with: .color(Color(.track)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    if let reached, reached > 0 {
                        var done = Path(); done.move(to: CGPoint(x: x(0), y: y)); done.addLine(to: CGPoint(x: x(reached), y: y))
                        g.stroke(done, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    guard live, session.status == .running, working, let current else { return }
                    let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = 1 - pow(1 - p, 3)
                    let from = current == 0 ? 0 : x(current - 1)
                    let px = from + (x(current) - from) * eased
                    let fade = p < 0.85 ? 1 : (1 - p) / 0.15
                    let glow = Gradient(colors: [accent.opacity(0.9 * fade), accent.opacity(0)])
                    g.fill(Path(ellipseIn: CGRect(x: px - 7, y: y - 7, width: 14, height: 14)),
                           with: .radialGradient(glow, center: CGPoint(x: px, y: y), startRadius: 0, endRadius: 7))
                    g.fill(Path(ellipseIn: CGRect(x: px - 2, y: y - 2, width: 4, height: 4)), with: .color(.white.opacity(fade)))
                }
            }
            .frame(height: 16)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element) { i, gate in
                    node(i, gate: gate).frame(maxWidth: .infinity)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .card, value: current)
    }

    @ViewBuilder
    private func node(_ i: Int, gate: String) -> some View {
        let s = state(gate)
        VStack(spacing: 4) {
            ZStack {
                if s == .current && i == current {
                    Circle().fill(Color(.accent).opacity(0.22))
                        .frame(width: 22, height: 22)
                        .matchedGeometryEffect(id: "highlight", in: ns)
                }
                switch s {
                case .pending:
                    Circle().strokeBorder(Color(.track), lineWidth: 2).frame(width: 12, height: 12)
                        .background(Circle().fill(.background))
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color(.accent))
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : (current ?? 0))
                case .current:
                    Circle().fill(Color(.accent)).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                case .failed:
                    FailedNode()
                }
            }
            .frame(width: 16, height: 16)
            Text(gate)
                .font(.caption2.weight(s == .current || s == .failed ? .semibold : .regular))
                .foregroundStyle(s == .current ? .primary : s == .failed ? Color(.failure) : s == .pending ? .secondary.opacity(0.6) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
                .help(gate)
            if let run = session.gateRuns[gate] {
                GateTime(run: run, live: live)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gate): \(Self.describe(s))")
    }

    private static func describe(_ s: NodeState) -> String {
        switch s {
        case .pending: "not run yet"
        case .done: "done"
        case .current: "in progress"
        case .failed: "failed"
        }
    }
}

private struct GateTime: View {
    let run: GateRun
    let live: Bool
    @AppStorage(GateRun.limitKey) private var limitMinutes = GateRun.defaultLimitMinutes

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !live || run.end != nil)) { context in
            let seconds = run.duration(now: context.date)
            Text(GateRun.format(seconds))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(seconds > limitMinutes * 60 ? Color(.waiting) : .secondary)
                .contentTransition(.numericText(value: seconds))
                .animation(.snappy, value: Int(seconds))
                .accessibilityLabel(GateRun.format(seconds) + (run.end == nil ? " so far" : ""))
        }
    }
}

private struct FailedNode: View {
    @State private var glow = 1.0

    var body: some View {
        Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.white, Color(.failure))
            .background(Circle().fill(Color(.failure)).blur(radius: 6).opacity(glow).scaleEffect(1.8))
            .onAppear { withAnimation(.easeOut(duration: 2)) { glow = 0 } }
    }
}


private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No active sessions").font(.callout.weight(.medium))
            Text("Start Claude Code and sessions appear here live.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct NotificationsOff: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell.slash.fill").foregroundStyle(Color(.waiting))
            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications are off").font(.caption.weight(.semibold))
                Text("Alerts and Allow/Deny prompts can't be shown; permission requests go to the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.waiting).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

private struct Footer: View {
    let store: SessionStore
    var actions: SessionActions?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(store.recentFolders.prefix(8), id: \.self) { folder in
                    Button(SessionStore.projectName(folder)) { actions?.newSession(in: folder) }
                }
                if !store.recentFolders.isEmpty { Divider() }
                Button("Choose Folder…") { if let folder = Self.chooseFolder() { actions?.newSession(in: folder) } }
                if !store.recentSessions.isEmpty {
                    Section("Resume") {
                        ForEach(store.recentSessions.prefix(8)) { s in
                            Button("\(s.project) · \(s.lastEventAt.formatted(.relative(presentation: .named)))") { actions?.resume(s) }
                        }
                    }
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("Start Claude Code in a recent project, or resume a recent session")
            Spacer()
            IconButton(icon: "folder", help: "Open transcript folder (~/.claude/projects)") {
                NSWorkspace.shared.open(home.appending(path: ".claude/projects"))
            }
            IconButton(icon: "gearshape", help: "Settings") { actions?.showSettings() }
            IconButton(icon: "power", help: "Quit Pitwall") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption.weight(.medium))
    }

    private static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Start Claude Code"
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

private struct CardButton: View {
    let id: String
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.demoHover) private var demoHover
    private var hover: Bool { hovering || demoHover == id }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 16)
                .background(.primary.opacity(hover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? .primary : .secondary)
        .onHover { hovering = $0 }
        .modifier(Spot(id: id))
        .help(help)
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.demoHover) private var demoHover
    private var hover: Bool { hovering || demoHover == icon }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 22)
                .background(.primary.opacity(hover ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? .primary : .secondary)
        .onHover { hovering = $0 }
        .modifier(Spot(id: icon))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct UsageText {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fK", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    static func cost(_ c: Double?, estimate: Bool = false) -> String {
        c.map { (estimate ? "≈ " : "") + String(format: "$%.2f", $0) } ?? "—"
    }
}

#if DEBUG
@MainActor
enum Mock {
    static func stores(now: Date = Date()) -> (SessionStore, UsageStore) {
        let store = SessionStore()
        store.definedAgents = { ["/x/menu-bar", "/x/web-app"].contains($0) ? ["architect", "planner", "developer", "verifier"] : [] }
        func e(_ name: String, _ session: String, _ cwd: String, ago: TimeInterval, tool: String? = nil,
               detail: String? = nil, agent: String? = nil, verdict: String? = nil,
               todos: [Todo]? = nil, task: TaskChange? = nil) {
            store.apply(HookEvent(timestamp: now - ago, sessionId: session, cwd: cwd, hookEventName: name,
                                  transcriptPath: nil, toolName: tool, toolDetail: detail, subagentType: agent, verdict: verdict,
                                  todos: todos, task: task))
        }
        e("SessionStart", "a", "/x/menu-bar", ago: 1500)
        e("PreToolUse", "a", "/x/menu-bar", ago: 1450, tool: "Agent", agent: "architect")
        e("SubagentStop", "a", "/x/menu-bar", ago: 1316, agent: "architect")
        e("PreToolUse", "a", "/x/menu-bar", ago: 1300, tool: "Agent", agent: "planner")
        e("SubagentStop", "a", "/x/menu-bar", ago: 1105, agent: "planner")
        e("PreToolUse", "a", "/x/menu-bar", ago: 734, tool: "Agent", agent: "developer")
        e("PostToolUse", "a", "/x/menu-bar", ago: 30, tool: "TodoWrite", todos: [
            Todo(content: "Model the session store", status: "completed"),
            Todo(content: "Draw the pipeline track", status: "completed"),
            Todo(content: "Wire the hook to the app", status: "completed"),
            Todo(content: "Run the test suite", status: "in_progress"),
            Todo(content: "Update the README", status: "pending")])
        e("PreToolUse", "a", "/x/menu-bar", ago: 4, tool: "Bash", detail: "xcodebuild -project Pitwall.xcodeproj -scheme Pitwall test")
        e("SessionStart", "b", "/x/web-app", ago: 900)
        e("PreToolUse", "b", "/x/web-app", ago: 520, tool: "Agent", agent: "architect")
        e("SubagentStop", "b", "/x/web-app", ago: 430, agent: "architect")
        e("PreToolUse", "b", "/x/web-app", ago: 300, tool: "Agent", agent: "planner")
        e("PreToolUse", "b", "/x/web-app", ago: 60, tool: "Edit", detail: "/x/web-app/src/routes/checkout.tsx")
        e("PostToolUse", "b", "/x/web-app", ago: 200, tool: "TaskCreate", task: TaskChange(id: "1", subject: "Plan the checkout flow"))
        e("PostToolUse", "b", "/x/web-app", ago: 190, tool: "TaskCreate", task: TaskChange(id: "2", subject: "Add payment step"))
        e("PostToolUse", "b", "/x/web-app", ago: 100, tool: "TaskUpdate", task: TaskChange(id: "1", status: "in_progress"))
        e("Notification", "b", "/x/web-app", ago: 50)
        e("SessionStart", "c", "/x/api", ago: 2400)
        e("PreToolUse", "c", "/x/api", ago: 400, tool: "Agent", agent: "verifier")
        e("SubagentStop", "c", "/x/api", ago: 120, agent: "verifier", verdict: "fail")
        e("PreToolUse", "c", "/x/api", ago: 100, tool: "Grep", detail: "func handleRefund")
        e("PostToolUse", "c", "/x/api", ago: 99, tool: "Grep")
        e("SessionStart", "d", "/x/docs", ago: 3000)
        e("PreToolUse", "d", "/x/docs", ago: 700, tool: "Agent", agent: "verifier")
        e("SubagentStop", "d", "/x/docs", ago: 650, agent: "verifier", verdict: "pass")
        e("Stop", "d", "/x/docs", ago: 640)

        let usage = UsageStore()
        for (id, k) in [("a", 1.0), ("b", 0.4), ("c", 2.2), ("d", 0.7)] {
            usage.entries[id] = [UsageEntry(model: "claude-sonnet-5-5", timestamp: now - 60, tokens: TokenUsage(
                input: Int(42_000 * k), output: Int(18_000 * k), cacheRead: Int(2_100_000 * k), cacheWrite5m: Int(160_000 * k)))]
        }
        usage.contexts = ["a": ContextUsage(tokens: 342_000, model: "claude-opus-5-5", at: now),
                          "b": ContextUsage(tokens: 156_000, model: "claude-sonnet-4-6", at: now),
                          "c": ContextUsage(tokens: 912_000, model: "claude-opus-5-5", at: now)]
        return (store, usage)
    }

    static let git: [String: GitInfo] = ["/x/menu-bar": GitInfo(branch: "main", changed: 4),
                                         "/x/web-app": GitInfo(branch: "feature/checkout-redesign", changed: 12),
                                         "/x/docs": GitInfo(branch: "main", changed: 0)]

    static var gitStore: GitStatusStore {
        let store = GitStatusStore()
        store.info = git
        return store
    }

    static var contextWindows: ContextWindows {
        Bundle.main.url(forResource: "context", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap(ContextWindows.decode) ?? .standard
    }

    static var prices: PriceTable {
        Bundle.main.url(forResource: "prices", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap(PriceTable.decode) ?? PriceTable(prices: [:])
    }
}

#Preview("Popover") {
    let (store, usage) = Mock.stores()
    return MenuView(store: store, usage: usage, prices: Mock.prices, contextWindows: Mock.contextWindows, git: Mock.gitStore)
}

#Preview("Popover · empty") {
    MenuView(store: SessionStore(), usage: UsageStore(), prices: PriceTable(prices: [:]))
}

#endif
