import Charts
import SwiftUI

struct AnalyticsView: View {
    let analytics: Analytics
    var active = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = analytics.saveError {
                Label("Analytics couldn't be saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(.failure))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cost = analytics.cost {
                Summary(cost: cost, cache: analytics.cache, pipeline: analytics.pipeline, models: analytics.models)
                Card {
                    CostChart(report: cost)
                    ProjectList(report: cost)
                }
                if let pipeline = analytics.pipeline {
                    Card { PipelineStats(report: pipeline) }
                }
                if !analytics.models.isEmpty {
                    Card { ModelAdvices(advices: analytics.models) }
                }
                if !analytics.config.isEmpty {
                    Card { ConfigImpacts(impacts: analytics.config) }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(analytics.store == nil ? "Analytics storage couldn't be opened." : "Importing the last 30 days…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(12)
        .task(id: active) { if active { await analytics.reload() } }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.card), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CardHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

struct Tile<Accessory: View>: View {
    let title: String
    let value: String
    let detail: String
    var tint = Color.secondary
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .center, spacing: 6) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                accessory
            }
            Text(detail).font(.caption2).foregroundStyle(tint).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.card), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension Tile where Accessory == EmptyView {
    init(title: String, value: String, detail: String, tint: Color = .secondary) {
        self.init(title: title, value: value, detail: detail, tint: tint) { EmptyView() }
    }
}

private struct Summary: View {
    let cost: CostReport
    let cache: CacheReport?
    let pipeline: PipelineReport?
    let models: [ModelAdvice]
    @AppStorage(BudgetSettings.modeKey) private var mode = BillingMode.api
    @AppStorage(CacheRatio.warnKey) private var warn = CacheRatio.defaultWarn

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Tile(title: mode == .subscription ? "API-equivalent · 7 days" : "Cost · 7 days",
                     value: UsageText.cost(cost.total, estimate: mode == .subscription), detail: change)
                cacheTile
            }
            GridRow {
                verifierTile
                savingsTile
            }
        }
    }

    private var change: String {
        guard let c = cost.change else { return "No data for the week before" }
        let percent = Int((abs(c) * 100).rounded())
        return percent == 0 ? "Same as the week before" : "\(c > 0 ? "↑" : "↓") \(percent)% vs the week before"
    }

    private var cacheTile: some View {
        let points = cache?.points ?? []
        let low = points.map(\.ratio).min()
        return Tile(title: "Cache hit · today", value: cache?.today.map(Self.percent) ?? "—",
                    detail: low.map { "7-day low \(Self.percent($0))" } ?? "No usage",
                    tint: (cache?.today).map { $0 * 100 < warn } == true ? Color(.waiting) : .secondary) {
            if points.count > 1 {
                Chart(points) { p in
                    LineMark(x: .value("Day", p.day), y: .value("Ratio", p.ratio))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(Color(.accent))
                }
                .chartYScale(domain: (points.map(\.ratio).min()! - 0.01)...(points.map(\.ratio).max()! + 0.01))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 52, height: 22)
                .accessibilityHidden(true)
            }
        }
        .help("Cache reads ÷ (cache reads + cache writes + input tokens), per day for the last 7 days.")
    }

    private var verifierTile: some View {
        guard let p = pipeline, p.verifierRuns > 0, let rate = p.failureRate else {
            return Tile(title: "Verifier · 7 days", value: "—", detail: "No verifier runs")
        }
        let passed = p.verifierRuns - p.verifierFailures
        return Tile(title: "Verifier · 7 days", value: Self.percent(1 - rate),
                    detail: "\(passed) of \(p.verifierRuns) runs passed",
                    tint: rate > 0.5 ? Color(.failure) : .secondary)
    }

    @ViewBuilder private var savingsTile: some View {
        let savings = models.compactMap(\.savings).filter { $0 >= 0.01 }.reduce(0, +)
        if savings > 0 {
            Tile(title: "Cheaper models", value: UsageText.cost(savings), detail: "less one tier down",
                 tint: Color(.running))
        } else {
            let runs = pipeline?.gates.reduce(0) { $0 + $1.runs } ?? 0
            Tile(title: "Subagent runs · 7 days", value: "\(runs)",
                 detail: pipeline?.slowest.map { "Slowest: \($0)" } ?? "No pipeline runs")
        }
    }

    private static func percent(_ r: Double) -> String { "\(Int((r * 100).rounded()))%" }
}

private func seriesColors(_ series: [String]) -> [Color] {
    let palette: [Color] = [Color(.chart1), Color(.chart2), Color(.chart3), Color(.chart4), Color(.chart5)]
    return series.enumerated().map { $1 == CostReport.other ? Color(.idle) : palette[$0 % palette.count] }
}

private struct CostChart: View {
    let report: CostReport
    @State private var hovered: Date?
    @AppStorage(BudgetSettings.modeKey) private var mode = BillingMode.api

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "Cost per day", detail: mode == .subscription ? "API-equivalent" : nil)
            Chart {
                ForEach(report.bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Cost", bar.cost), width: .ratio(0.6))
                        .foregroundStyle(by: .value("Project", bar.series))
                        .cornerRadius(3)
                        .opacity(hovered == nil || hovered == bar.day ? 1 : 0.35)
                }
                if hovered == nil, let peak = peak {
                    PointMark(x: .value("Day", peak.day, unit: .day), y: .value("Cost", peak.cost))
                        .opacity(0)
                        .annotation(position: .top, spacing: 3) {
                            Text(UsageText.cost(peak.cost)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        }
                }
            }
            .chartForegroundStyleScale(domain: report.series, range: seriesColors(report.series))
            .chartXScale(domain: report.days[0]...Calendar.current.date(byAdding: .day, value: 1, to: report.days[6])!)
            .chartXAxis {
                AxisMarks(values: report.days) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel { Text("$\(Int(value.as(Double.self) ?? 0))").font(.caption2) }
                }
            }
            .chartYScale(domain: 0...Swift.max(1, (peak?.cost ?? 0) * 1.18))
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let point) = phase, let plot = proxy.plotFrame,
                                  let date: Date = proxy.value(atX: point.x - g[plot].origin.x) else {
                                hovered = nil
                                return
                            }
                            hovered = report.days.last { $0 <= date }
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if let hovered { DayDetail(day: hovered, report: report).allowsHitTesting(false) }
            }
            .frame(height: 140)
            .accessibilityLabel("Cost per day for the last 7 days")
        }
    }

    private var peak: (day: Date, cost: Double)? {
        let totals = Dictionary(grouping: report.bars, by: \.day).mapValues { $0.reduce(0) { $0 + $1.cost } }
        return totals.max { $0.value < $1.value }.flatMap { $0.value > 0 ? ($0.key, $0.value) : nil }
    }
}

private struct PipelineStats: View {
    let report: PipelineReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "Pipeline", detail: report.gates.isEmpty ? nil : "avg · median")
            if report.gates.isEmpty {
                Text("No finished subagent runs in the last 7 days.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let scale = report.gates.map { max($0.average, $0.median) }.max()! * 1.05
                VStack(spacing: 6) {
                    let pipeline = report.gates.filter(\.isPipeline), other = report.gates.filter { !$0.isPipeline }
                    ForEach(pipeline) { row($0, scale: scale) }
                    if !other.isEmpty {
                        Text(pipeline.isEmpty ? "Agents" : "Other agents")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, pipeline.isEmpty ? 0 : 4)
                        ForEach(other) { row($0, scale: scale) }
                    }
                }
                .help("Bar: average run time. Diamond: median. Highlighted: the gate that took the most time in total.")
                if let slowest = report.slowest, let g = report.gates.first(where: { $0.name == slowest }) {
                    Label("\(slowest) takes the most time: \(GateRun.format(g.total)) in \(g.runs) runs",
                          systemImage: "tortoise.fill")
                        .font(.caption)
                        .foregroundStyle(Color(.accent))
                }
            }
        }
    }

    private func row(_ g: PipelineReport.Gate, scale: TimeInterval) -> some View {
        let slowest = g.name == report.slowest
        return HStack(spacing: 8) {
            HStack(spacing: 3) {
                Text(g.name).lineLimit(1).truncationMode(.tail)
                Text("×\(g.runs)").foregroundStyle(.secondary).fixedSize()
            }
            .help(g.name)
            .fontWeight(slowest ? .semibold : .regular)
            .foregroundStyle(slowest ? Color(.accent) : .primary)
            .frame(width: 128, alignment: .leading)
            Chart {
                BarMark(xStart: .value("Start", 0), xEnd: .value("Average", g.average),
                        y: .value("Gate", g.name), height: 8)
                    .foregroundStyle(slowest ? Color(.accent) : Color(.track))
                    .clipShape(Capsule())
                PointMark(x: .value("Median", g.median), y: .value("Gate", g.name))
                    .symbol(.diamond)
                    .symbolSize(28)
                    .foregroundStyle(Color(nsColor: .labelColor))
            }
            .chartXScale(domain: 0...scale)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 14)
            Text("\(GateRun.format(g.average)) · \(GateRun.format(g.median))")
                .monospacedDigit()
                .foregroundStyle(slowest ? Color(.accent) : .secondary)
                .frame(width: 96, alignment: .trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.name): \(g.runs) runs, average \(GateRun.format(g.average)), "
                            + "median \(GateRun.format(g.median))" + (slowest ? ", takes the most time" : ""))
    }
}

private struct DayDetail: View {
    let day: Date
    let report: CostReport

    var body: some View {
        let bars = report.bars(on: day)
        let colors = Dictionary(uniqueKeysWithValues: zip(report.series, seriesColors(report.series)))
        VStack(alignment: .leading, spacing: 3) {
            Text(day, format: .dateTime.weekday(.wide).day().month())
                .font(.caption.weight(.semibold))
            if bars.isEmpty { Text("No usage").foregroundStyle(.secondary) }
            ForEach(bars.reversed()) { bar in
                HStack(spacing: 6) {
                    Circle().fill(colors[bar.series] ?? .gray).frame(width: 6, height: 6)
                    Text(bar.series).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(UsageText.cost(bar.cost)).monospacedDigit()
                }
            }
            if bars.count > 1 {
                Divider()
                HStack {
                    Text("Total")
                    Spacer()
                    Text(UsageText.cost(bars.reduce(0) { $0 + $1.cost })).monospacedDigit()
                }
                .fontWeight(.semibold)
            }
        }
        .font(.caption)
        .padding(8)
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4, y: 2)
    }
}

private struct ConfigImpacts: View {
    let impacts: [ConfigImpact]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Config changes", detail: "30 days")
            ForEach(impacts) { i in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(i.change.label).lineLimit(1).truncationMode(.tail).help(i.change.files.joined(separator: "\n"))
                        Spacer(minLength: 8)
                        Text("\(i.project) · \(i.change.at.formatted(.dateTime.month(.abbreviated).day()))")
                            .foregroundStyle(.secondary).fixedSize()
                    }
                    verdict(i)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func verdict(_ i: ConfigImpact) -> some View {
        let percent = { (r: Double?) in r.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
        guard i.isMeasured, let before = i.before.rate, let after = i.after.rate else {
            return Label("Verifier: \(i.before.runs) runs before, \(i.after.runs) after: too few to compare",
                         systemImage: "hourglass")
                .foregroundStyle(Color.secondary)
        }
        let delta = after - before
        return Label("Verifier fails \(percent(before)) → \(percent(after)) (\(i.before.runs) → \(i.after.runs) runs)",
                     systemImage: abs(delta) < 0.05 ? "equal" : delta < 0 ? "arrow.down.right" : "arrow.up.right")
            .foregroundStyle(abs(delta) < 0.05 ? Color.secondary : delta < 0 ? Color(.running) : Color(.failure))
    }
}

private struct ModelAdvices: View {
    let advices: [ModelAdvice]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Models", detail: "one tier down")
            ForEach(advices) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(a.gate).lineLimit(1).truncationMode(.tail).help(a.gate)
                        Spacer(minLength: 8)
                        Text(a.models.map { ModelAdvice.name($0.model) }.joined(separator: ", "))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Text(UsageText.cost(a.cost)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                    }
                    if let cheaper = a.cheaper, let savings = a.savings, savings >= 0.01 {
                        Label("On \(ModelAdvice.name(cheaper)): \(UsageText.cost(savings)) less (−\(Int((savings / a.cost * 100).rounded()))%)",
                              systemImage: "arrow.down.right")
                            .foregroundStyle(Color(.running))
                    }
                    let measured = a.models.filter { $0.verifier.runs > 0 }
                    if !measured.isEmpty {
                        Label("Verifier after it: " + measured.map {
                            "\(ModelAdvice.name($0.model)) passed \($0.verifier.runs - $0.verifier.failures) of \($0.verifier.runs)"
                        }.joined(separator: " · "), systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
            Text("Same tokens at the cheaper model's prices. To compare quality, change the agent's model in "
                 + ".claude/agents: the verifier result per model shows here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProjectList: View {
    let report: CostReport

    private struct Row: Identifiable {
        let name: String
        let cost: Double
        let tokens: Int
        var id: String { name }
    }

    private var rows: [Row] {
        let top = report.projects.prefix(CostReport.top).map { Row(name: $0.project, cost: $0.cost, tokens: $0.tokens) }
        let rest = report.projects.dropFirst(CostReport.top)
        return rest.isEmpty ? top : top + [Row(name: "\(rest.count) more", cost: rest.reduce(0) { $0 + $1.cost },
                                                tokens: rest.reduce(0) { $0 + $1.tokens })]
    }

    var body: some View {
        let colors = seriesColors(report.series)
        let max = report.projects.first?.cost ?? 0
        VStack(spacing: 7) {
            if report.projects.isEmpty {
                Text("No usage in the last 7 days.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                let color = i < colors.count ? colors[i] : Color(.idle)
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(row.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.track).opacity(0.4))
                        Capsule().fill(color).frame(width: max > 0 ? Swift.max(3, 56 * min(1, row.cost / max)) : 3)
                    }
                    .frame(width: 56, height: 4)
                    Text(UsageText.cost(row.cost)).frame(minWidth: 58, alignment: .trailing)
                }
                .font(.caption)
                .monospacedDigit()
                .help("\(row.name): \(UsageText.tokens(row.tokens)) tokens")
                .accessibilityElement(children: .combine)
            }
        }
    }
}
