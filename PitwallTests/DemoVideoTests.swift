import AVFoundation
import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import Pitwall

/// Records a demo video (1080×1350 MP4, for social posts) of the real popover playing a scripted story on
/// made-up sessions and a made-up week of analytics: no real data is read.
/// Opt-in: TEST_RUNNER_DEMO_DIR=/some/dir xcodebuild ... test -only-testing:PitwallTests/DemoVideoTests
/// It opens a popover on screen for about 30 s and clicks its tabs: leave that corner of the screen alone.
@MainActor
final class DemoVideoTests: XCTestCase {
    private let dir: URL! = ProcessInfo.processInfo.environment["DEMO_DIR"].map { URL(fileURLWithPath: $0) }
    private static let duration = 38.0, fps = 30
    private static let canvas = CGSize(width: 1080, height: 1350), menuBar: CGFloat = 46

    override func setUpWithError() throws {
        try XCTSkipIf(dir == nil, "the demo video is opt-in")
    }

    /// One captured window: its PNG, its size in points, and named points in it (from the top left, in points).
    private struct Shot {
        let url: URL
        let size: CGSize
        let points: [String: CGPoint]
    }

    /// What was on screen at one moment: the popover, the Stop alert and the Settings window, when shown.
    private struct Frame {
        let t: Double
        let popover: Shot?, alert: Shot?, settings: Shot?
        let mark: MarkState
        let markSince: Double
    }

    /// Hover in the popover follows the drawn pointer: SwiftUI's onHover ignores synthetic mouse events.
    @Observable @MainActor final class Pointer {
        var hover: String?
    }

    private struct Root: View {
        let menu: MenuView
        let pointer: Pointer
        let spots: Spots

        var body: some View {
            menu.environment(\.demoHover, pointer.hover).environment(\.spots, spots)
        }
    }

    @available(macOS, deprecated: 14.0, message: "CGWindowListCreateImage; ScreenCaptureKit would need Screen Recording permission")
    func testRecordDemo() async throws {
        let now = Date()
        let root = dir.appending(path: "demo-data")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Analytics: a week of made-up transcripts and pipeline runs.
        let prices = Mock.prices
        let store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: true))
        let events = try Demo.history(in: root, now: now)
        await store.importTranscripts(root: root.appending(path: "projects"), defaults: UserDefaults(suiteName: "demo-\(UUID())")!, now: now)
        await store.ingestEvents(url: events)
        let analytics = Analytics(store: store, prices: prices)
        await analytics.reload()
        analytics.budget = await store.budget(prices: prices)

        let sessions = SessionStore(), usage = UsageStore(), git = GitStatusStore()
        Demo.sessions(sessions, usage, git, now: now)
        var pid = HookEvent(timestamp: now, sessionId: "s1", cwd: "/Users/demo/storefront", hookEventName: "PreToolUse", transcriptPath: nil,
                            toolName: "Bash", toolDetail: "npm test -- cart", subagentType: nil, verdict: nil, todos: nil)
        pid.pid = 48213 // a plausible pid for the alert; the video never stops anything
        sessions.apply(pid)
        let defaults = UserDefaults(suiteName: "demo-\(UUID())")!
        defaults.set(BillingMode.api.rawValue, forKey: BudgetSettings.modeKey)
        defaults.set(60.0, forKey: BudgetSettings.dailyBudgetKey)
        let state = PopoverState(), pointer = Pointer(), spots = Spots()
        let hosting = NSHostingController(rootView: Root(menu: MenuView(store: sessions, usage: usage, prices: prices,
                                                                        contextWindows: Mock.contextWindows, git: git,
                                                                        analytics: analytics, popover: state),
                                                         pointer: pointer, spots: spots)
            .defaultAppStorage(defaults))
        hosting.sizingOptions = []
        let popover = NSPopover()
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = hosting
        popover.contentSize = CGSize(width: 360, height: hosting.view.fittingSize.height)
        let resizer = PopoverResizer(popover: popover, state: state)

        // A plain dark backdrop under the popover, so its material shows the same color on any desktop.
        let screen = NSScreen.main!.visibleFrame
        let anchorRect = CGRect(x: screen.midX - 20, y: screen.maxY - 22, width: 40, height: 20)
        let backdrop = NSWindow(contentRect: CGRect(x: anchorRect.midX - 260, y: screen.maxY - 900, width: 520, height: 900),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false // closed below, and released by ARC
        backdrop.backgroundColor = NSColor(red: 0.05, green: 0.10, blue: 0.12, alpha: 1)
        backdrop.orderFrontRegardless()
        let anchor = NSWindow(contentRect: anchorRect, styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.backgroundColor = .clear
        anchor.isOpaque = false
        anchor.orderFrontRegardless()
        defer { popover.close(); anchor.close(); backdrop.close(); _ = resizer }

        // The Stop confirmation as the app builds it (shown, never run modally: nothing is stopped), and Settings.
        var alert: NSAlert?
        func showAlert() {
            guard let session = sessions.sessions["s1"] else { return }
            let a = SessionActions.stopAlert(session)
            a.window.appearance = NSAppearance(named: .darkAqua)
            a.layout()
            a.window.setFrameOrigin(CGPoint(x: screen.minX + 40, y: screen.midY - 100))
            a.window.orderFrontRegardless()
            alert = a
        }
        let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(hotKey: HotKey()).defaultAppStorage(defaults)))
        settings.title = "Pitwall Settings"
        settings.styleMask = [.titled, .closable]
        settings.isReleasedWhenClosed = false
        settings.appearance = NSAppearance(named: .darkAqua)
        let fitting = settings.contentViewController!.view.fittingSize
        settings.setContentSize(CGSize(width: fitting.width, height: min(fitting.height, 460)))
        settings.setFrameTopLeftPoint(CGPoint(x: screen.minX + 40, y: screen.maxY - 40))
        defer { settings.close(); alert?.window.close() }

        // The story, in seconds from the start of the video.
        let s = sessions
        func ev(_ name: String, _ id: String, tool: String? = nil, detail: String? = nil, agent: String? = nil,
                verdict: String? = nil, todos: [Todo]? = nil) {
            s.apply(HookEvent(timestamp: Date(), sessionId: id, cwd: "/Users/demo/\(Demo.folder[id]!)", hookEventName: name,
                              transcriptPath: nil, toolName: tool, toolDetail: detail, subagentType: agent, verdict: verdict,
                              todos: todos))
        }
        var clicks: [(Double, MenuView.Tab)] = [(14.8, .analytics), (20.8, .sessions)]
        var script: [(Double, () -> Void)] = [
            (0.5, { state.openedAt = Date(); popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY) }),
            (4.0, { ev("Notification", "s2") }),
            (7.0, { ev("PreToolUse", "s2", tool: "Bash", detail: "pytest -q tests/refunds") }),
            (8.5, { ev("PreToolUse", "s1", tool: "Edit", detail: "src/cart/CheckoutSummary.tsx") }),
            (10.0, { ev("SubagentStop", "s2", agent: "verifier", verdict: "fail") }),
            (12.5, { ev("PreToolUse", "s2", tool: "Agent", agent: "developer") }),
            (13.3, { ev("PostToolUse", "s1", tool: "TodoWrite", todos: Demo.todos(done: 4)) }),
            (22.0, { ev("SubagentStop", "s2", agent: "developer") }),
            (22.2, { ev("PreToolUse", "s2", tool: "Agent", agent: "verifier") }),
            (22.9, { ev("Stop", "s1") }),
            (24.7, { pointer.hover = "s1/resume" }),
            (25.7, { pointer.hover = "s1/stop" }),
            (26.3, { showAlert() }),
            (27.7, { alert?.window.orderOut(nil); alert = nil; pointer.hover = nil }),
            (29.0, { pointer.hover = "gearshape" }),
            (29.3, { settings.orderFrontRegardless() }),
            (29.5, { popover.performClose(nil); pointer.hover = nil }),
            (34.0, { settings.orderOut(nil) }),
            (23.6, { ev("SubagentStop", "s2", agent: "verifier", verdict: "pass") }),
        ]

        // Capture: as fast as the window server gives frames; PNGs are written off the main thread.
        let framesDir = dir.appending(path: "frames")
        try? FileManager.default.removeItem(at: framesDir)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let writes = DispatchGroup()
        var frames: [Frame] = []
        var mark = MarkState(session: s.headline), markSince = 0.0
        let start = Date()
        while true {
            let t = Date().timeIntervalSince(start)
            guard t < Self.duration else { break }
            while let next = script.first, next.0 <= t { script.removeFirst(); next.1() }
            if let next = clicks.first, next.0 <= t, let window = hosting.view.window, let tab = state.tabFrames[next.1] {
                clicks.removeFirst()
                click(CGPoint(x: tab.midX, y: tab.midY), in: hosting.view, window: window)
            }
            let headline = MarkState(session: s.headline)
            if headline != mark { (mark, markSince) = (headline, t) }
            func shoot(_ window: NSWindow, _ name: String, points: [String: CGPoint]) -> Shot? {
                guard window.isVisible, let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                                         [.boundsIgnoreFraming, .bestResolution]) else { return nil }
                let file = framesDir.appending(path: String(format: "%05d-\(name).png", frames.count))
                DispatchQueue.global(qos: .userInitiated).async(group: writes) {
                    guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { return }
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                }
                return Shot(url: file, size: window.frame.size, points: points)
            }
            func top(_ view: NSView, _ p: CGPoint) -> CGPoint {
                let w = view.convert(p, to: nil)
                return CGPoint(x: w.x, y: (view.window?.frame.height ?? 0) - w.y)
            }
            func center(_ view: NSView) -> CGPoint { top(view, CGPoint(x: view.bounds.midX, y: view.bounds.midY)) }
            var named = spots.frames
            for (tab, frame) in state.tabFrames { named["tab.\(tab)"] = frame }
            let popoverShot = popover.isShown ? hosting.view.window.flatMap { window in
                shoot(window, "popover", points: named.mapValues { top(hosting.view, CGPoint(x: $0.midX, y: $0.midY)) })
            } : nil
            let alertShot = alert.flatMap { a in shoot(a.window, "alert", points: a.buttons.count > 1 ? ["cancel": center(a.buttons[1])] : [:]) }
            let settingsShot = shoot(settings, "settings",
                                     points: settings.standardWindowButton(.closeButton).map { ["close": center($0)] } ?? [:])
            frames.append(Frame(t: t, popover: popoverShot, alert: alertShot, settings: settingsShot, mark: mark, markSince: markSince))
            try await Task.sleep(for: .milliseconds(12))
        }
        await withCheckedContinuation { done in writes.notify(queue: .main) { done.resume() } }
        print("demo: \(frames.count) frames captured in \(Self.duration) s")

        try await encode(frames, to: dir.appending(path: "pitwall-demo.mp4"))
        try? FileManager.default.removeItem(at: framesDir)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Story data

    private func click(_ point: CGPoint, in view: NSView, window: NSWindow) {
        let p = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
        }
    }

    // MARK: - Composition

    /// What the caption says when: chapter, title, subtitle.
    private static let captions: [(Double, String, String, String)] = [
        (0, "Sessions", "Every Claude Code session", "status, gate and cost at a glance"),
        (4, "Attention", "Know when Claude needs you", "waiting sessions turn yellow"),
        (9.6, "Verification", "Catch a failing verifier", "before it reaches review"),
        (13.8, "Analytics", "Cost, cache and pipeline", "a week of usage, per project"),
        (21.2, "Pipeline", "Ship when every gate is green", "architect → planner → developer → verifier"),
        (24.2, "Actions", "Resume or stop from the card", "Stop asks first, and only signals Claude Code"),
        (28.0, "Settings", "Tuned to your workflow", "budget, thresholds, verifier pattern, shortcut"),
    ]
    private static let endCard = 34.4

    private func encode(_ frames: [Frame], to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let size = Self.canvas
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), String(describing: writer.error))
        writer.startSession(atSourceTime: .zero)

        // Near full size, so it reads on a phone; the camera pans to what doesn't fit.
        let scale: CGFloat = 0.95
        let desk = Self.desktop()
        let shownAt = frames.first { $0.popover != nil }?.t ?? 0
        var cache: [URL: NSImage] = [:]
        var known: [String: CGPoint] = [:]
        var index = 0
        for i in 0..<Int(Self.duration * Double(Self.fps)) {
            let t = Double(i) / Double(Self.fps)
            while index + 1 < frames.count, frames[index + 1].t <= t { index += 1 }
            let frame = frames[index]
            func image(_ shot: Shot?) -> NSImage? {
                guard let url = shot?.url else { return nil }
                if cache[url] == nil {
                    if cache.count > 6 { cache.removeAll() }
                    cache[url] = NSImage(contentsOf: url)
                }
                return cache[url]
            }
            let windows = (popover: image(frame.popover), alert: image(frame.alert), settings: image(frame.settings))
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { return XCTFail("no pixel buffer pool: \(String(describing: writer.error))") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return XCTFail("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let cg = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            draw(cg, t: t, frame: frame, windows: windows, scale: scale, desk: desk, shownAt: shownAt, known: &known)
            NSGraphicsContext.restoreGraphicsState()
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(Self.fps)))
        }
        input.markAsFinished()
        let done = expectation(description: "video written")
        writer.finishWriting { done.fulfill() }
        await fulfillment(of: [done], timeout: 60)
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    /// One video frame, drawn top-left origin: backdrop, fake menu bar with the live mark, the popover, cursor, captions.
    private func draw(_ cg: CGContext, t: Double, frame: Frame, windows: (popover: NSImage?, alert: NSImage?, settings: NSImage?),
                      scale: CGFloat, desk: Desktop, shownAt: Double, known: inout [String: CGPoint]) {
        let popover = windows.popover
        let size = Self.canvas
        let accent = NSColor(resource: .accent), ending = smooth((t - Self.endCard) / 0.8)
        // The camera: holds on the top, pans down through Analytics and back, then down to the footer for Settings.
        let footer = CGPoint(x: 0, y: max(0, (known["popover/gearshape"]?.y ?? 0) - (size.height - 470)))
        let camera = path([(0, CGPoint.zero), (15.9, .zero), (17.3, CGPoint(x: 0, y: 440)), (19.0, CGPoint(x: 0, y: 440)),
                           (20.3, .zero), (28.0, .zero), (28.9, footer), (29.4, footer), (30.2, .zero)], t).y
        cg.saveGState()
        cg.translateBy(x: 0, y: -camera)
        // The desktop: the wallpaper, and a menu bar that blurs it, with the status items of a real Mac.
        for (image, height) in [(desk.wallpaper, CGFloat(desk.wallpaper.height)), (desk.menuBar, Self.menuBar)] {
            NSImage(cgImage: image, size: .zero).draw(in: CGRect(x: 0, y: 0, width: size.width, height: height), from: .zero,
                                                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSColor.black.withAlphaComponent(0.22).setFill()
        CGRect(x: 0, y: 0, width: size.width, height: Self.menuBar).fill()
        let markRect = CGRect(x: size.width / 2 - 22, y: 1, width: 44, height: 44)
        if popover != nil { // highlighted while open, like a real status item
            NSColor.white.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: CGRect(x: markRect.minX - 6, y: 5, width: markRect.width + 12, height: Self.menuBar - 10),
                         xRadius: 9, yRadius: 9).fill()
        }
        drawMark(frame.mark, t: t - frame.markSince, in: markRect)
        let clock = NSAttributedString(string: "Fri 30 Oct  14:41", attributes: [
            .font: NSFont.systemFont(ofSize: 25, weight: .medium), .foregroundColor: NSColor.white])
        let clockX = size.width - clock.size().width - 24
        clock.draw(at: CGPoint(x: clockX, y: (Self.menuBar - clock.size().height) / 2))
        for (i, name) in ["switch.2", "magnifyingglass", "wifi", "battery.75percent", "speaker.wave.2.fill"].enumerated() {
            symbol(name, at: CGPoint(x: clockX - 40 - CGFloat(i) * 56, y: Self.menuBar / 2))
        }
        for (i, name) in ["timer", "doc.on.clipboard"].enumerated() {
            symbol(name, at: CGPoint(x: markRect.minX - 40 - CGFloat(i) * 56, y: Self.menuBar / 2))
        }
        let mark = CGPoint(x: size.width / 2, y: 24)
        // A captured window on the canvas at the video's scale; its named points are remembered in canvas pixels.
        func place(_ image: NSImage?, _ shot: Shot?, _ name: String, at origin: (CGSize) -> CGPoint, fraction: CGFloat = 1) {
            guard let image, let shot else { return }
            let w = image.size.width * scale, h = image.size.height * scale
            let rect = CGRect(origin: origin(CGSize(width: w, height: h)), size: CGSize(width: w, height: h))
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
            cg.restoreGState()
            let k = w / shot.size.width
            for (key, p) in shot.points { known["\(name)/\(key)"] = CGPoint(x: rect.minX + p.x * k, y: rect.minY + p.y * k) }
        }
        // The popover hangs from the menu bar; the alert and Settings open where macOS puts them.
        place(popover, frame.popover, "popover", at: { CGPoint(x: (size.width - $0.width) / 2, y: Self.menuBar + 4) },
              fraction: smooth((t - shownAt) / 0.2) * (1 - 0.75 * ending))
        place(windows.settings, frame.settings, "settings", at: { CGPoint(x: (size.width - $0.width) / 2, y: Self.menuBar + 60) })
        place(windows.alert, frame.alert, "alert", at: { CGPoint(x: (size.width - $0.width) / 2, y: 300) })
        // The pointer: rests beside the popover between actions, never on its content, and fades out.
        func at(_ key: String) -> CGPoint { known[key] ?? rest }
        let rest = CGPoint(x: size.width / 2 + 390, y: 270)
        let settings = known["settings/close"].map { CGPoint(x: $0.x + 520, y: $0.y + 330) } ?? rest
        let keys: [(Double, CGPoint)] = [
            (0, CGPoint(x: 760, y: 420)), (0.38, mark), (1.0, mark), (2.0, rest),
            (13.6, rest), (14.6, at("popover/tab.analytics")), (15.1, at("popover/tab.analytics")), (15.8, rest),
            (19.9, rest), (20.6, at("popover/tab.sessions")), (21.1, at("popover/tab.sessions")), (21.8, rest),
            (23.9, rest), (24.6, at("popover/s1/resume")), (25.3, at("popover/s1/resume")),
            (25.7, at("popover/s1/stop")), (26.4, at("popover/s1/stop")),
            (27.1, at("alert/cancel")), (27.75, at("alert/cancel")),
            (28.9, at("popover/gearshape")), (29.5, at("popover/gearshape")),
            (30.6, settings), (32.4, settings), (33.4, at("settings/close")), (34.05, at("settings/close")), (34.6, rest),
        ]
        let alpha = ending > 0 ? 0 : max(fade(t, 0, 2.0), fade(t, 13.4, 15.8), fade(t, 19.7, 21.8), fade(t, 23.7, 34.6))
        drawPointer(at: path(keys, t), alpha: alpha)
        cg.restoreGState()
        // Lower third: chapter, title, subtitle, cross-fading; chapter pills; then the end card.
        let shade = CGGradient(colorsSpace: nil, colors: [NSColor.black.withAlphaComponent(0).cgColor,
                                                           NSColor.black.withAlphaComponent(0.92).cgColor] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(shade, start: CGPoint(x: 0, y: size.height - 440), end: CGPoint(x: 0, y: size.height - 270),
                              options: [.drawsAfterEndLocation])
        let chapter = Self.captions.lastIndex(where: { $0.0 <= t }) ?? 0
        if ending < 1 {
            let (from, eyebrow, title, subtitle) = Self.captions[chapter]
            let until = chapter + 1 < Self.captions.count ? Self.captions[chapter + 1].0 : Self.endCard
            let a = smooth((t - from) / 0.4) * (1 - smooth((t - until + 0.35) / 0.35))
            let rise = 12 * (1 - smooth((t - from) / 0.5))
            centered(String(format: "%02d  ·  %@", chapter + 1, eyebrow.uppercased()), size: 22, weight: .semibold,
                     color: accent, alpha: a, y: size.height - 250 + rise, kern: 4)
            centered(title, size: 56, weight: .bold, color: .white, alpha: a, y: size.height - 190 + rise)
            centered(subtitle, size: 30, weight: .regular, color: NSColor.white.withAlphaComponent(0.62), alpha: a, y: size.height - 128 + rise)
            let pill = CGSize(width: 44, height: 5), gap: CGFloat = 10
            let x0 = (size.width - CGFloat(Self.captions.count) * (pill.width + gap) + gap) / 2
            for i in Self.captions.indices {
                let color = i == chapter ? accent : NSColor.white.withAlphaComponent(i < chapter ? 0.45 : 0.15)
                color.withAlphaComponent(color.alphaComponent * (1 - ending)).setFill()
                NSBezierPath(roundedRect: CGRect(x: x0 + CGFloat(i) * (pill.width + gap), y: size.height - 64, width: pill.width, height: pill.height),
                             xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
        if ending > 0 {
            NSColor.black.withAlphaComponent(0.55 * ending).setFill()
            CGRect(x: 0, y: Self.menuBar, width: size.width, height: size.height - Self.menuBar).fill()
            let rise = 30 * (1 - ending)
            let hero = CGRect(x: size.width / 2 - 110, y: 260 + rise, width: 220, height: 220)
            Mark.draw(cg, in: hero, state: MarkState(mode: .running), t: t - Self.endCard, template: false)
            centered("Pitwall", size: 96, weight: .heavy, color: .white, alpha: ending, y: 560 + rise)
            centered("A menu bar companion for Claude Code", size: 38, weight: .medium, color: accent, alpha: ending, y: 650 + rise)
            centered("Sessions  ·  Pipeline gates  ·  Cost  ·  Allow/Deny from notifications", size: 28, weight: .regular,
                     color: NSColor.white.withAlphaComponent(0.7), alpha: smooth((t - Self.endCard - 0.5) / 0.6), y: 730 + rise)
            centered("macOS  ·  Swift  ·  100% local, no network", size: 28, weight: .regular,
                     color: NSColor.white.withAlphaComponent(0.7), alpha: smooth((t - Self.endCard - 0.9) / 0.6), y: 780 + rise)
        }
    }

    /// 0 → 1 over 0.25 s from `from`, back to 0 over 0.3 s before `to`.
    private func fade(_ t: Double, _ from: Double, _ to: Double) -> CGFloat {
        smooth((t - from) / 0.25) * (1 - smooth((t - to + 0.3) / 0.3))
    }

    /// The menu bar mark as MarkAnimator plays it: loops, a settling failure, a pass that returns to the idle template.
    private func drawMark(_ state: MarkState, t: Double, in rect: CGRect) {
        var state = state, t = t
        switch state.mode {
        case .running, .waiting: t = t.truncatingRemainder(dividingBy: Mark.period(state)!)
        case .failed: t = min(t, Mark.failSettle)
        case .passed where t > Mark.sweepDuration: (state.mode, t) = (.idle, 0)
        default: break
        }
        let image = Mark.image(state, t: t, dark: true)
        if image.isTemplate { // tint the idle template white, as the menu bar does
            let tinted = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                NSColor.white.withAlphaComponent(0.9).set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The system arrow cursor, at the video's scale (about 1.9 px per point), its hot spot on `p`.
    private func drawPointer(at p: CGPoint, alpha: CGFloat) {
        guard alpha > 0 else { return }
        let cursor = NSCursor.arrow, k: CGFloat = 1.9
        let size = CGSize(width: cursor.image.size.width * k, height: cursor.image.size.height * k)
        cursor.image.draw(in: CGRect(x: p.x - cursor.hotSpot.x * k, y: p.y - cursor.hotSpot.y * k, width: size.width, height: size.height),
                          from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// A white SF Symbol, the size of the menu bar's own.
    private func symbol(_ name: String, at center: CGPoint) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular)) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                               width: image.size.width, height: image.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    struct Desktop {
        let wallpaper: CGImage, menuBar: CGImage
    }

    /// This Mac's wallpaper (or Sonoma's), filling the canvas plus the camera's pan, and the menu bar's blurred strip of it.
    private static func desktop() -> Desktop {
        let size = CGSize(width: canvas.width, height: canvas.height + 440)
        let candidates = [NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) },
                          URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")]
        let source = candidates.compactMap { $0 }.lazy.compactMap { url in
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }.first
        let cg = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        if let source {
            let fill = max(size.width / CGFloat(source.width), size.height / CGFloat(source.height))
            let w = CGFloat(source.width) * fill, h = CGFloat(source.height) * fill
            cg.draw(source, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        } else {
            cg.setFillColor(NSColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
        }
        let wallpaper = cg.makeImage()!
        let ci = CIImage(cgImage: wallpaper)
        let strip = CGRect(x: 0, y: size.height - menuBar, width: size.width, height: menuBar)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 30).cropped(to: strip)
        let menuBar = CIContext().createCGImage(blurred, from: strip)!
        return Desktop(wallpaper: wallpaper, menuBar: menuBar)
    }

    private func centered(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, alpha: CGFloat, y: CGFloat,
                          kern: CGFloat = 0) {
        guard alpha > 0 else { return }
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .kern: kern,
            .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha)])
        s.draw(at: CGPoint(x: (Self.canvas.width - s.size().width) / 2, y: y - s.size().height / 2))
    }

    /// Eased position along timed keyframes.
    private func path(_ keys: [(Double, CGPoint)], _ t: Double) -> CGPoint {
        guard let next = keys.firstIndex(where: { $0.0 > t }) else { return keys.last!.1 }
        guard next > 0 else { return keys[0].1 }
        let (t0, a) = keys[next - 1], (t1, b) = keys[next]
        let k = smooth((t - t0) / (t1 - t0))
        return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    private func smooth(_ x: Double) -> CGFloat {
        let x = min(1, max(0, x))
        return x * x * (3 - 2 * x)
    }
}
