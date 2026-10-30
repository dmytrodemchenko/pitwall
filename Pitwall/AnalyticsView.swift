import Charts
import SwiftUI

struct AnalyticsView: View {
    let analytics: Analytics
    var active = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = analytics.saveError {
                Label("Analytics couldn't be saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cost = analytics.cost {
                CostChart(report: cost)
                ProjectList(report: cost)
                if let cache = analytics.cache {
                    Divider().opacity(0.5)
                    CacheChart(report: cache)
                }
                if let pipeline = analytics.pipeline {
                    Divider().opacity(0.5)
                    PipelineStats(report: pipeline)
                }
                if !analytics.config.isEmpty {
                    Divider().opacity(0.5)
                    ConfigImpacts(impacts: analytics.config)
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
            HStack(alignment: .firstTextBaseline) {
                Text(mode == .subscription ? "API-equivalent cost per day" : "Cost per day").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(UsageText.cost(report.total, estimate: mode == .subscription)) · 7 days").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart {
                ForEach(report.bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Cost", bar.cost))
                        .foregroundStyle(by: .value("Project", bar.series))
                        .opacity(hovered == nil || hovered == bar.day ? 1 : 0.4)
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
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(UsageText.cost(value.as(Double.self))) }
                }
            }
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
            .frame(height: 150)
            .accessibilityLabel("Cost per day for the last 7 days")
        }
    }
}

private struct CacheChart: View {
    let report: CacheReport
    @AppStorage(CacheRatio.warnKey) private var warn = CacheRatio.defaultWarn

    private var low: Double {
        let lowest = report.points.map { $0.ratio * 100 }.min() ?? 100
        return max(0, ((lowest - 3) / 5).rounded(.down) * 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cache hit ratio").font(.subheadline.weight(.semibold))
                Spacer()
                Text(report.today.map { "\(Int(($0 * 100).rounded()))% today" } ?? "No usage today")
                    .font(.caption)
                    .foregroundStyle(report.today.map { $0 * 100 < warn } == true ? Color(.waiting) : .secondary)
                    .monospacedDigit()
            }
            Chart {
                if warn >= low {
                    RuleMark(y: .value("Warning", warn))
                        .foregroundStyle(Color(.waiting).opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(report.points) { p in
                    LineMark(x: .value("Day", p.day, unit: .day), y: .value("Ratio", p.ratio * 100))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", p.day, unit: .day), y: .value("Ratio", p.ratio * 100))
                        .symbolSize(24)
                        .annotation(position: .top, spacing: 2) {
                            Text(p.ratio, format: .percent.precision(.fractionLength(0))).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                }
                .foregroundStyle(Color(.accent))
            }
            .chartYScale(domain: low...(100 + (100 - low) * 0.25))
            .chartXScale(domain: report.days[0]...Calendar.current.date(byAdding: .day, value: 1, to: report.days[6])!)
            .chartXAxis {
                AxisMarks(values: report.days) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [low, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text((value.as(Double.self) ?? 0) / 100, format: .percent) }
                }
            }
            .frame(height: 80)
            .help("Cache reads ÷ (cache reads + cache writes + input tokens). Dashed line: the warning threshold "
                  + "(\(Int(warn))% in Settings), when it falls in the chart's range.")
            .accessibilityLabel("Cache hit ratio for the last 7 days" + (report.today.map { ", \(Int($0 * 100)) percent today" } ?? ""))
        }
    }
}

private struct PipelineStats: View {
    let report: PipelineReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline · 7 days").font(.subheadline.weight(.semibold))
            if report.gates.isEmpty {
                Text("No finished subagent runs in the last 7 days.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let scale = report.gates.map { max($0.average, $0.median) }.max()! * 1.05
                VStack(spacing: 6) {
                    HStack {
                        Spacer()
                        Text("avg · median").frame(width: 96, alignment: .trailing)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
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
            if let rate = report.failureRate {
                Label("Verifier failed \(report.verifierFailures) of \(report.verifierRuns) runs (\(Int((rate * 100).rounded()))%)",
                      systemImage: report.verifierFailures == 0 ? "checkmark.seal" : "xmark.seal")
                    .font(.caption)
                    .foregroundStyle(report.verifierFailures == 0 ? Color.secondary : Color(.failure))
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
            Text("Config changes · 30 days").font(.subheadline.weight(.semibold))
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

private struct ProjectList: View {
    let report: CostReport

    var body: some View {
        let colors = Dictionary(uniqueKeysWithValues: zip(report.series, seriesColors(report.series)))
        VStack(spacing: 6) {
            HStack {
                Text("Projects · 7 days")
                Spacer()
                Text("tokens · cost")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            if report.projects.isEmpty {
                Text("No usage in the last 7 days.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(report.projects) { p in
                HStack(spacing: 8) {
                    Circle().fill(colors[p.project] ?? colors[CostReport.other] ?? .gray).frame(width: 7, height: 7)
                    Text(p.project).lineLimit(1).truncationMode(.tail).help(p.project)
                    Spacer(minLength: 8)
                    Text("\(UsageText.tokens(p.tokens)) tok").foregroundStyle(.secondary)
                    Text(UsageText.cost(p.cost)).frame(minWidth: 56, alignment: .trailing)
                }
                .font(.caption)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
    }
}
