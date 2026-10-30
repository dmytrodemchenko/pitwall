import SwiftUI

struct TaskReplayView: View {
    let history: TaskHistory
    let prices: PriceTable
    @State private var selection: ReplayTask.ID?

    var body: some View {
        NavigationSplitView {
            TaskList(history: history, prices: prices, selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            if let task = history.shown.first(where: { $0.id == selection }) ?? history.shown.first {
                TaskDetail(task: task, prices: prices).id(task.id)
            } else if history.loading {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView("No Tasks", systemImage: "clock.arrow.circlepath",
                                       description: Text("Prompts from the last \(Int(TaskHistory.days)) days show up here."))
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onChange(of: history.session) { selection = nil }
        .task(id: history.shown.first?.id) {
            if !history.shown.contains(where: { $0.id == selection }) { selection = history.shown.first?.id }
        }
    }
}

private struct TaskList: View {
    let history: TaskHistory
    let prices: PriceTable
    @Binding var selection: ReplayTask.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(history.shown) { task in
                TaskRow(task: task, prices: prices).tag(task.id)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                if history.session != nil {
                    Text("One session").font(.caption.weight(.semibold))
                    Button("Show All") { history.session = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Text("Last \(Int(TaskHistory.days)) days").font(.caption.weight(.semibold))
                }
                Spacer()
                if history.loading { ProgressView().controlSize(.mini) }
                Button { Task { await history.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload transcripts")
                    .accessibilityLabel("Reload transcripts")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

private struct TaskRow: View {
    let task: ReplayTask
    let prices: PriceTable

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(task.prompt).font(.callout).lineLimit(2)
                Spacer(minLength: 0)
                TaskStatus(task: task, compact: true)
            }
            Text("\(task.project) · \(task.start.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("\(GateRun.format(task.duration)) · ^[\(task.calls) tool call](inflect: true) · \(UsageText.cost(task.cost(prices), estimate: true))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct TaskStatus: View {
    let task: ReplayTask
    var compact = false

    private var state: (String, String, Color) {
        if task.interrupted { return ("Interrupted", "stop.circle.fill", Color(.waiting)) }
        if !task.isComplete { return ("No final response", "circle.dashed", Color(.idle)) }
        if task.errors > 0 {
            return (task.errors == 1 ? "1 error" : "\(task.errors) errors", "exclamationmark.triangle.fill", Color(.failure))
        }
        return ("Completed", "checkmark.circle.fill", Color(.running))
    }

    var body: some View {
        let (text, icon, tint) = state
        if compact {
            Image(systemName: icon).foregroundStyle(tint).font(.caption).help(text).accessibilityLabel(text)
        } else {
            Label(text, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(tint)
        }
    }
}

struct TaskDetail: View {
    let task: ReplayTask
    let prices: PriceTable
    @State var filter = ReplayFilter.all
    @State private var fullPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(task.project) · \(task.start.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                        TaskStatus(task: task)
                    }
                    Text(task.prompt)
                        .font(.title3.weight(.semibold))
                        .lineLimit(fullPrompt ? nil : 4)
                        .textSelection(.enabled)
                    if task.prompt.count > 300 || task.prompt.split(whereSeparator: \.isNewline).count > 4 {
                        Button(fullPrompt ? "Show less" : "Show full prompt") { fullPrompt.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Metrics(task: task, prices: prices)
                if !task.agents.isEmpty || !task.files.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        if !task.files.isEmpty { Card { FileList(files: task.files) } }
                        if !task.agents.isEmpty { Card { AgentList(task: task) } }
                    }
                }
                Card {
                    CardHeader(title: "Final response")
                    Text(task.response.map(Self.markdown) ?? AttributedString(task.interrupted ? "Interrupted before a final response." : "No final response yet."))
                        .font(.callout)
                        .foregroundStyle(task.response == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Card { Timeline(task: task, filter: $filter) }
            }
            .padding(16)
        }
    }
}

extension TaskDetail {
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct Metrics: View {
    let task: ReplayTask
    let prices: PriceTable

    var body: some View {
        let t = task.tokens, slowest = task.events.filter(\.isCall).compactMap(\.duration).max()
        let models = Set(task.usage.map(\.model)).map(ModelAdvice.name).sorted().joined(separator: ", ")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            Tile(title: "Duration", value: GateRun.format(task.duration),
                 detail: task.start.formatted(date: .omitted, time: .shortened) + " – " + task.end.formatted(date: .omitted, time: .shortened))
            Tile(title: "Estimated cost", value: UsageText.cost(task.cost(prices)), detail: models.isEmpty ? "no usage recorded" : models)
            Tile(title: "Tokens", value: UsageText.tokens(t.total),
                 detail: "\(UsageText.tokens(t.output)) out · \(UsageText.tokens(t.cacheRead)) cache read")
            Tile(title: "Tool calls", value: "\(task.calls)", detail: slowest.map { "slowest \(GateRun.format($0))" } ?? "none")
            Tile(title: "Errors", value: "\(task.errors)",
                 detail: task.retries == 1 ? "1 API retry" : "\(task.retries) API retries",
                 tint: task.errors + task.retries > 0 ? Color(.failure) : .secondary)
            Tile(title: "Files", value: "\(task.files.count)",
                 detail: "\(task.files.filter { $0.ops.contains { $0 != .read } }.count) changed")
        }
    }
}

private struct FileList: View {
    let files: [(path: String, ops: [ReplayEvent.FileOp])]
    @State private var all = false

    var body: some View {
        CardHeader(title: "Files", detail: "\(files.count)")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(files.prefix(all ? files.count : 8).enumerated()), id: \.offset) { _, f in
                HStack(spacing: 6) {
                    ForEach(f.ops, id: \.self) { op in
                        Text(op.rawValue)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(op.tint.opacity(0.18), in: Capsule())
                            .foregroundStyle(op == .read ? .secondary : .primary)
                    }
                    Text(f.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(f.path)
                }
            }
            if files.count > 8, !all {
                Button("\(files.count - 8) more") { all = true }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

private struct AgentList: View {
    let task: ReplayTask

    var body: some View {
        CardHeader(title: "Agents", detail: "\(task.agents.count)")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(task.agents, id: \.self) { agent in
                let events = task.events.filter { $0.agent == agent }
                let span = events.map(\.at).min().flatMap { a in events.map { $0.end ?? $0.at }.max().map { $0.timeIntervalSince(a) } }
                HStack {
                    Text(agent).font(.caption.weight(.medium))
                    Spacer()
                    Text("^[\(events.filter(\.isCall).count) call](inflect: true) · \(GateRun.format(span ?? 0))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

private struct Timeline: View {
    let task: ReplayTask
    @Binding var filter: ReplayFilter

    var body: some View {
        let shown = task.events.filter(filter.matches)
        CardHeader(title: "Timeline", detail: "\(shown.count) of \(task.events.count) events")
        Picker("Show", selection: $filter) {
            ForEach(ReplayFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if shown.isEmpty {
            Text("Nothing to show for this filter.").font(.caption).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { EventRow(event: $0, start: task.start) }
        }
    }
}

private struct EventRow: View {
    let event: ReplayEvent
    let start: Date
    @State private var open = false

    private var more: String? {
        [event.detail, event.result.map { "→ " + $0 }].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("+" + GateRun.format(event.at.timeIntervalSince(start)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                Image(systemName: event.icon).foregroundStyle(event.tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let agent = event.agent {
                            Text(agent)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color(.chart3).opacity(0.18), in: Capsule())
                        }
                        Text(event.title).font(.callout).lineLimit(open ? nil : 1)
                    }
                    if event.failed, let result = event.result, !open {
                        Text(result).font(.caption).foregroundStyle(Color(.failure)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let d = event.duration, event.isCall {
                    Text(GateRun.format(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if event.isCall {
                    Text("no result").font(.caption).foregroundStyle(.secondary)
                }
            }
            if open, let more {
                Text(more)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.leading, 90)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if more != nil { open.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(more != nil ? .isButton : [])
        .accessibilityHint(more != nil ? "Shows details" : "")
    }
}

private extension ReplayEvent {
    var icon: String {
        switch kind {
        case .message: "text.bubble"
        case .tool:
            switch tool {
            case "Bash", "PowerShell": "terminal"
            case "Grep", "Glob": "magnifyingglass"
            case "WebFetch", "WebSearch": "globe"
            case "TodoWrite", "TaskCreate", "TaskUpdate": "checklist"
            default: "wrench.and.screwdriver"
            }
        case .file(.read): "doc.text"
        case .file(.create): "doc.badge.plus"
        case .file(.edit): "pencil"
        case .file(.delete): "trash"
        case .agent: "person.2"
        case .retry: "arrow.clockwise"
        case .interrupt: "stop.circle"
        }
    }

    var tint: Color {
        if failed, kind != .retry { return Color(.failure) }
        switch kind {
        case .retry, .interrupt: return Color(.waiting)
        case .agent: return Color(.chart3)
        case .file(let op): return op.tint
        default: return .secondary
        }
    }
}

private extension ReplayEvent.FileOp {
    var tint: Color {
        switch self {
        case .read: .secondary
        case .create: Color(.running)
        case .edit: Color(.chart2)
        case .delete: Color(.failure)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
