import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Pitwall

/// Renders the popover (live ~/.claude-monitor data and mock data) and the mark's animation frames.
/// Opt-in: TEST_RUNNER_SNAPSHOT_DIR=/some/dir xcodebuild ... test
@MainActor
final class SnapshotTests: XCTestCase {
    private let dir: URL! = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }

    override func setUpWithError() throws {
        try XCTSkipIf(dir == nil, "snapshot rendering is opt-in")
    }

    @MainActor
    func testRenderPopover() throws {
        let monitor = Monitor { _ in }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            try render(MenuView(store: monitor.store, usage: monitor.usage, prices: monitor.prices),
                       scheme: scheme, to: "menu-\(name).png")
            let (store, usage) = Mock.stores()
            try render(MenuView(store: store, usage: usage, prices: Mock.prices), scheme: scheme, to: "menu-mock-\(name).png")
            // The cards alone: the popover scrolls once they overflow, and ImageRenderer can't draw a ScrollView.
            let cards = VStack(spacing: 8) {
                ForEach(store.activeSessions) { s in
                    SessionCard(session: s, entries: usage.entries(for: s.id), prices: Mock.prices, live: false,
                                context: usage.contexts[s.id], contextWindows: Mock.contextWindows,
                                git: s.folder.flatMap { Mock.git[$0] })
                }
            }
            .padding(12)
            .frame(width: 360)
            try render(cards, scheme: scheme, to: "cards-mock-\(name).png")
        }
    }

    /// The Analytics tab on this Mac's real transcripts (in-memory store; prints how long the 30-day import took).
    @MainActor
    func testRenderAnalytics() async throws {
        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true))
        let start = Date()
        await store.importTranscripts(defaults: UserDefaults(suiteName: "snapshot-\(UUID())")!)
        print("analytics import: \(Date().timeIntervalSince(start)) s")
        let monitor = Monitor { _ in }
        let analytics = Analytics(store: store, prices: monitor.prices)
        await store.ingestEvents()
        (analytics.cost, analytics.cache, analytics.pipeline) = await store.reports(prices: monitor.prices, pattern: Verifier.defaultPattern)
        // Config changes: made-up runs around a planner change (10 → 40% before, 15% after) and one too recent to tell.
        let runs = (0..<20).map { (i: Int) -> GateRunItem in
            let failed = i < 10 ? i % 5 < 2 : i % 7 == 0
            return GateRunItem(session: "s", gate: "verifier", start: t0, end: t0 + Double(i) * 3600, verdict: failed ? "fail" : "pass")
        }
        analytics.config = ConfigImpact.compare(changes: [ConfigChange(at: t0 + 9.5 * 3600, files: [".claude/agents/planner.md"]),
                                                          ConfigChange(at: t0 + 18.5 * 3600, files: ["CLAUDE.md"])],
                                                runs: runs, project: "storefront", pattern: Verifier.defaultPattern).reversed()
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            try render(AnalyticsView(analytics: analytics).frame(width: 360), scheme: scheme, to: "analytics-\(name).png")
        }
        // No session in the event log yet (right after an install): the header still shows today's transcripts.
        await analytics.refreshBudget(alert: false)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            try render(MenuView(store: SessionStore(), usage: UsageStore(), prices: monitor.prices, analytics: analytics),
                       scheme: scheme, to: "menu-fresh-\(name).png")
        }
        // The budget row in both modes, with its own defaults (the test host shares the real app's defaults).
        let status = await store.budget(prices: monitor.prices)
        let api = UserDefaults(suiteName: "snapshot-api")!, sub = UserDefaults(suiteName: "snapshot-sub")!
        api.set("api", forKey: BudgetSettings.modeKey); api.set(50.0, forKey: BudgetSettings.dailyBudgetKey)
        sub.set("subscription", forKey: BudgetSettings.modeKey); sub.set(2_000_000, forKey: BudgetSettings.windowLimitKey)
        let rows = VStack(spacing: 16) {
            BudgetRow(status: status).defaultAppStorage(api)
            BudgetRow(status: status).defaultAppStorage(sub)
        }
        .padding(16)
        .frame(width: 360)
        try render(rows, scheme: .dark, to: "budget-dark.png")
    }

    /// One row per state, frames left to right; plus an animated GIF of each state at menu bar size.
    @MainActor
    func testRenderMarkFrames() throws {
        let states = [MarkState(mode: .idle), MarkState(mode: .running), MarkState(mode: .running, gate: "developer"),
                      MarkState(mode: .waiting, gate: "planner"), MarkState(mode: .failed, gate: "verifier"), MarkState(mode: .passed)]
        let times = stride(from: 0.0, through: 1.6, by: 0.2).map { $0 }
        for (name, dark) in [("light", false), ("dark", true)] {
            let strip = VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 10) {
                        ForEach(times, id: \.self) { t in
                            Image(nsImage: Mark.image(s, t: t, dark: dark)).resizable().frame(width: 60, height: 60)
                        }
                        Text(Mark.accessibilityText(s).replacingOccurrences(of: "Pitwall: ", with: ""))
                            .font(.caption).frame(width: 150, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .foregroundStyle(dark ? .white : .black)
            .background(dark ? Color(white: 0.16) : Color(white: 0.96))
            try render(strip, scheme: dark ? .dark : .light, to: "mark-frames-\(name).png")
        }

        // The blind test: the mascot alone, large, no labels. Show it to someone and ask what it is.
        let blind = HStack(spacing: 24) {
            ForEach([MarkState(mode: .running), MarkState(mode: .passed), MarkState(mode: .waiting)], id: \.mode) { s in
                Image(nsImage: Mark.image(s, t: 0.9, dark: false)).resizable().frame(width: 160, height: 160)
            }
        }
        .padding(24)
        .background(Color.white)
        try render(blind, scheme: .light, to: "mascot-blind.png")

        // Animated GIF: every state for ~2 s, at 4x menu bar size, on a dark menu bar.
        let url = dir.appending(path: "mark.gif") as CFURL
        let fps = 24.0, perState = 48
        let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, states.count * perState, nil))
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for s in states {
            for f in 0..<perState {
                let frame = ZStack {
                    Color(white: 0.16)
                    Image(nsImage: Mark.image(s, t: Double(f) / fps, dark: true)).resizable().frame(width: 80, height: 80)
                        .foregroundStyle(.white)
                }.frame(width: 120, height: 100)
                let r = ImageRenderer(content: frame.environment(\.colorScheme, .dark))
                let cg = try XCTUnwrap(r.cgImage)
                CGImageDestinationAddImage(gif, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            }
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))
    }

    /// The popover's mascot stage from the moment it opens, every state, as one GIF (30 fps).
    @MainActor
    func testRenderStage() throws {
        let states = [MarkState(mode: .running, gate: "developer"), MarkState(mode: .waiting, gate: "planner"),
                      MarkState(mode: .failed, gate: "verifier"), MarkState(mode: .passed), MarkState(mode: .idle)]
        let fps = 30.0, perState = 105
        let url = dir.appending(path: "stage.gif") as CFURL
        let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, states.count * perState, nil))
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let opened = Date()
        for s in states {
            let stage = MascotStage(state: s, openedAt: opened, reduceMotion: false)
            for f in 0..<perState {
                let now = opened + Double(f) / fps
                let frame = Canvas { ctx, size in stage.draw(&ctx, size: size, now: now) }
                    .frame(width: 360, height: 70)
                    .background(Color(white: 0.16))
                    .environment(\.colorScheme, .dark)
                let r = ImageRenderer(content: frame)
                r.scale = 1.5
                CGImageDestinationAddImage(gif, try XCTUnwrap(r.cgImage),
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            }
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))

        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let stills = VStack(spacing: 0) {
                ForEach(states, id: \.mode) { s in
                    let stage = MascotStage(state: s, openedAt: opened, reduceMotion: false)
                    Canvas { ctx, size in stage.draw(&ctx, size: size, now: opened + (s.mode == .passed ? 0.8 : 2.2)) }
                        .frame(width: 360, height: 70)
                }
            }
            try render(stills, scheme: scheme, to: "stage-\(name).png")
        }
    }

    @MainActor
    private func render(_ view: some View, scheme: ColorScheme, to name: String) throws {
        let bg = scheme == .dark ? Color(white: 0.13) : Color(white: 0.93)
        let renderer = ImageRenderer(content: view.background(bg).environment(\.colorScheme, scheme))
        renderer.scale = 2
        let tiff = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            .write(to: dir.appending(path: name))
    }
}
