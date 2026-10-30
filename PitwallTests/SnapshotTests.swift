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
        analytics.models = await store.modelAdvice(prices: monitor.prices, pattern: Verifier.defaultPattern)
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

    /// The Settings window: a Form scrolls, so it is drawn from a hosting view, not ImageRenderer.
    @MainActor
    func testRenderSettings() throws {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: SettingsView(hotKey: HotKey()).frame(width: 480, height: 1100))
            view.appearance = NSAppearance(named: appearance)
            view.frame = CGRect(x: 0, y: 0, width: 480, height: 1100)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: "settings-\(name).png"))
        }
    }

    /// The Task Replay window on a made-up session (`replay-{light,dark}.png`, transcript kept in `replay-fixture/`)
    /// and on this Mac's transcripts (`replay-live-*.png`; prints how long loading the last 7 days took).
    /// Offscreen caching draws the list's selected row as a black block; check selection in the running app.
    @MainActor
    func testRenderTaskReplay() async throws {
        let root = dir.appending(path: "replay-fixture")
        try? FileManager.default.removeItem(at: root)
        let project = root.appending(path: "-x-storefront"), sub = project.appending(path: "demo/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let start = Date() - 3600
        func line(_ s: Double, _ fields: [String: Any]) -> String {
            var d = fields
            d["timestamp"] = ISO8601DateFormatter().string(from: start + s)
            d["cwd"] = "/x/storefront"
            d["uuid"] = UUID().uuidString
            return String(decoding: try! JSONSerialization.data(withJSONObject: d), as: UTF8.self)
        }
        func user(_ s: Double, _ text: String) -> String { line(s, ["type": "user", "message": ["role": "user", "content": text]]) }
        func call(_ s: Double, _ id: String, _ name: String, _ input: [String: Any], output: Int = 900) -> String {
            line(s, ["type": "assistant", "message": ["id": "m-\(id)", "model": "claude-opus-5-5",
                     "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
                     "usage": ["input_tokens": 40, "output_tokens": output, "cache_read_input_tokens": 60_000]]])
        }
        func say(_ s: Double, _ id: String, _ text: String) -> String {
            line(s, ["type": "assistant", "message": ["id": "m-\(id)", "model": "claude-opus-5-5", "content": [["type": "text", "text": text]],
                     "usage": ["input_tokens": 20, "output_tokens": 400, "cache_read_input_tokens": 60_000]]])
        }
        func result(_ s: Double, _ id: String, _ text: String, error: Bool = false) -> String {
            line(s, ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": error]]]])
        }
        let f = "/x/storefront/src/checkout/"
        let main = [
            user(-900, "Also update the changelog"),
            call(-896, "u1", "Read", ["file_path": "/x/storefront/CHANGELOG.md"]), result(-895, "u1", "## Unreleased"),
            user(-860, "[Request interrupted by user]"),
            user(0, "The checkout total is wrong when a coupon and free shipping are combined. Find the bug, fix it, and add a test."),
            say(4, "a", "I'll look at how the total is computed first."),
            call(6, "t1", "Grep", ["pattern": "applyCoupon"]), result(7, "t1", "src/checkout/total.ts\nsrc/checkout/coupon.ts"),
            call(9, "t2", "Read", ["file_path": f + "total.ts"]), result(10, "t2", "export function total(cart) { … }"),
            call(12, "t3", "Read", ["file_path": f + "coupon.ts"]), result(13, "t3", "export function applyCoupon(…) { … }"),
            line(20, ["type": "system", "subtype": "api_error", "retryAttempt": 1, "maxRetries": 10, "error": ["message": "Overloaded"]]),
            call(41, "t4", "Edit", ["file_path": f + "total.ts"]), result(42, "t4", "String to replace not found in file.", error: true),
            call(48, "t5", "Edit", ["file_path": f + "total.ts"], output: 2400), result(49, "t5", "The file has been updated."),
            call(55, "t6", "Write", ["file_path": f + "total.test.ts"], output: 3100), result(56, "t6", "File created successfully."),
            call(60, "t7", "Bash", ["command": "npm test -- checkout"]), result(84, "t7", "Tests: 1 failed, 41 passed", error: true),
            call(90, "t8", "Edit", ["file_path": f + "total.ts"]), result(91, "t8", "The file has been updated."),
            call(94, "t9", "Agent", ["subagent_type": "verifier", "description": "Verify the checkout fix"]),
            result(171, "t9", "VERDICT: PASS"),
            call(175, "t10", "Bash", ["command": "rm src/checkout/total.old.ts"]), result(176, "t10", ""),
            say(180, "z", "Fixed. The coupon discount was applied after free shipping zeroed the shipping line, so the discount was taken twice. `total()` now applies coupons to the subtotal only, and `total.test.ts` covers the combined case. The verifier passed."),
        ]
        try main.joined(separator: "\n").write(to: project.appending(path: "demo.jsonl"), atomically: true, encoding: .utf8)
        try [
            call(97, "v1", "Read", ["file_path": f + "total.ts"], output: 300), result(98, "v1", "…"),
            call(101, "v2", "Bash", ["command": "npm test"], output: 300), result(150, "v2", "Tests: 42 passed"),
            say(168, "v3", "All 42 tests pass and the combined case is covered.\nVERDICT: PASS"),
        ].joined(separator: "\n").write(to: sub.appending(path: "agent-v.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"verifier","toolUseId":"t9"}"#.write(to: sub.appending(path: "agent-v.meta.json"), atomically: true, encoding: .utf8)

        let demo = TaskHistory(root: root)
        await demo.reload()
        let live = TaskHistory()
        let loading = Date()
        await live.reload()
        print("task replay load: \(Date().timeIntervalSince(loading)) s, \(live.tasks.count) tasks")
        let again = Date()
        await live.reload()
        print("task replay reload (cached): \(Date().timeIntervalSince(again)) s")
        let checkout = try XCTUnwrap(demo.tasks.first { $0.prompt.hasPrefix("The checkout") })
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: TaskDetail(task: checkout, prices: Mock.prices, filter: .errors)
                .frame(width: 700, height: 1000).background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: appearance)
            view.frame = CGRect(x: 0, y: 0, width: 700, height: 1000)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: "replay-errors-\(name).png"))
        }
        for (history, prefix) in [(demo, "replay"), (live, "replay-live")] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let window = NSWindow(contentViewController: NSHostingController(rootView: TaskReplayView(history: history, prices: Mock.prices)
                    .background(Color(nsColor: .windowBackgroundColor))))
                window.appearance = NSAppearance(named: appearance)
                window.contentView?.appearance = NSAppearance(named: appearance)
                window.setContentSize(CGSize(width: 980, height: 900))
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                view.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: "\(prefix)-\(name).png"))
            }
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
