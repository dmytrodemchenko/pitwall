import os
import SwiftUI

@main
struct PitwallApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let notifier = Notifier()
    private var monitor: Monitor!
    private let item = NSStatusBar.system.statusItem(withLength: Mark.size.width + 8)
    private let markLayer = CALayer()
    private var frameCache: (key: String, frames: [Int: Any]) = ("", [:])
    private let popover = NSPopover()
    private let popoverState = PopoverState()
    private var resizer: PopoverResizer?
    private let animator = MarkAnimator()
    private let actions = SessionActions()
    private let hotKey = HotKey()
    private var analytics: Analytics!
    private var settingsWindow: NSWindow?
    private let permissions = PermissionServer(
        path: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-monitor/monitor.sock").path)

    func applicationDidFinishLaunching(_ notification: Notification) {
        umask(0o077)
        let me = NSRunningApplication.current
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil, !Demo.isOn,
           NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
               .contains(where: { $0 != me && !$0.isTerminated }) {
            Logger.app.notice("another copy is already running; quitting")
            exit(0)
        }
        let notifier = notifier
        if Demo.isOn {
            startDemo()
        } else {
            monitor = Monitor(notify: notifier.post)
            startAnalytics()
        }

        let hosting = NSHostingController(rootView: MenuView(store: monitor.store, usage: monitor.usage, prices: monitor.prices,
                                                         notifier: notifier, actions: actions,
                                                         contextWindows: monitor.contextWindows, git: monitor.git,
                                                         analytics: analytics, popover: popoverState))
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.contentSize = CGSize(width: 360, height: hosting.view.fittingSize.height)
        resizer = PopoverResizer(popover: popover, state: popoverState)
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle)
        if let button = item.button {
            button.wantsLayer = true
            markLayer.frame = CGRect(x: (button.bounds.width - Mark.size.width) / 2,
                                     y: (button.bounds.height - Mark.size.height) / 2,
                                     width: Mark.size.width, height: Mark.size.height)
            markLayer.contentsGravity = .resizeAspect
            button.layer?.addSublayer(markLayer)
        }

        actions.showSettings = { [weak self] in self?.showSettings() }
        if !Demo.isOn {
            startPermissionServer()
            startHotKey()
        }
        animator.onFrame = { [weak self] in self?.draw() }
        track()
        draw()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissions.stop()
    }

    private func startPermissionServer() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        permissions.onRequest = { [weak self] p in
            guard let self else { return }
            let project = monitor.store.sessions[p.request.sessionId]?.project ?? SessionStore.projectName(p.request.cwd)
            notifier.ask(p, project: project)
        }
        monitor.isAwaitingPermission = { [weak self] in self?.permissions.hasPending(session: $0) ?? false }
        do {
            try permissions.start()
        } catch {
            Logger.app.error("permission socket \(self.permissions.path, privacy: .private) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func startDemo() {
        let root = FileManager.default.temporaryDirectory.appending(path: "pitwall-demo")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root.appending(path: "monitor"), withIntermediateDirectories: true)
        monitor = Monitor(dir: root.appending(path: "monitor"), notify: { _ in })
        let now = Date()
        Demo.sessions(monitor.store, monitor.usage, monitor.git, now: now)
        let change = Demo.configChange(now: now)
        let store = try? AnalyticsStore(container: AnalyticsStore.container(inMemory: true),
                                        configChanges: { folder, _ in folder.hasSuffix("/storefront") ? [change] : [] })
        let analytics = Analytics(store: store, prices: monitor.prices)
        self.analytics = analytics
        let prices = monitor.prices
        Task {
            guard let store else { return }
            await Demo.load(analytics, store: store, root: root, prices: prices, now: now)
        }
    }

    private func startAnalytics() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        var store: AnalyticsStore?
        do {
            store = AnalyticsStore(container: try AnalyticsStore.container(inMemory: testing))
        } catch {
            Logger.app.error("analytics store failed: \(String(describing: error), privacy: .public)")
        }
        let notifier = notifier
        analytics = Analytics(store: store, prices: monitor.prices, alerts: BudgetAlerts(notify: notifier.post))
        monitor.onTranscript = { [weak self] in self?.analytics.ingest(transcript: $0) }
        monitor.onEvents = { [weak self] in self?.analytics.ingestEvents() }
        monitor.onLoop = { notifier.loop($1, session: $0.session) }
        notifier.onStop = { [weak self] id in
            guard let self, let s = monitor.store.sessions[id], !s.isEnded else { return }
            actions.stop(s)
        }
        if !testing { analytics.start() }
    }

    private func startHotKey() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, popover.isShown, event.window == popover.contentViewController?.view.window
            else { return event }
            popover.performClose(nil)
            return nil
        }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        hotKey.onPress = { [weak self] in self?.toggle() }
        do {
            try hotKey.register(hotKey.saved)
        } catch {
            Logger.app.error("hotkey: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(hotKey: hotKey)))
            window.title = "Pitwall Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func popoverWillShow(_ notification: Notification) { popoverState.openedAt = Date() }
    func popoverDidClose(_ notification: Notification) { popoverState.openedAt = nil }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func draw() {
        guard let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let intro = animator.state.mode == .running ? Mark.intro(animator.t) : nil
        let scale = button.window?.backingScaleFactor ?? 2
        if intro == nil, let frame = cachedFrame(dark: dark, scale: scale) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if button.image != nil { button.image = nil }
            markLayer.contentsScale = scale
            markLayer.contents = frame
            CATransaction.commit()
            button.setAccessibilityLabel(Mark.accessibilityText(animator.state))
            return
        }
        let image = Mark.image(animator.state, t: animator.t, dark: dark, pose: intro ?? Mark.Pose())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image.isTemplate {
            markLayer.contents = nil
            button.image = image
        } else {
            if button.image != nil { button.image = nil }
            markLayer.contentsScale = scale
            markLayer.contents = image.layerContents(forContentsScale: scale)
        }
        button.setAccessibilityLabel(image.accessibilityDescription)
        CATransaction.commit()
    }

    private func cachedFrame(dark: Bool, scale: CGFloat) -> Any? {
        guard let period = Mark.period(animator.state) else { return nil }
        let fps = MarkAnimator.fps
        let count = Int((period * fps).rounded())
        let index = Int(animator.t * fps) % count
        let key = "\(animator.state)|\(dark)|\(scale)"
        if frameCache.key != key { frameCache = (key, [:]) }
        if let frame = frameCache.frames[index] { return frame }
        let frame = Mark.image(animator.state, t: Double(index) / fps, dark: dark).layerContents(forContentsScale: scale)
        frameCache.frames[index] = frame
        return frame
    }

    private func track() {
        withObservationTracking {
            animator.show(MarkState(session: monitor.store.headline))
        } onChange: {
            DispatchQueue.main.async { self.track() }
        }
    }
}

@MainActor
final class PopoverResizer {
    private let popover: NSPopover
    private let state: PopoverState
    private var timer: Timer?
    private var spring: (from: CGFloat, to: CGFloat, start: Date)?

    init(popover: NSPopover, state: PopoverState) {
        self.popover = popover
        self.state = state
        trackHeight()
    }

    private func trackHeight() {
        withObservationTracking {
            resize(to: state.height)
        } onChange: {
            DispatchQueue.main.async { self.trackHeight() }
        }
    }

    private func resize(to wanted: CGFloat) {
        let height = wanted.rounded()
        guard height > 0, abs((spring?.to ?? popover.contentSize.height) - height) > 0.5 else { return }
        timer?.invalidate()
        guard popover.isShown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            popover.animates = true
            popover.contentSize.height = height
            return
        }
        spring = (popover.contentSize.height, height, Date())
        popover.animates = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let (from, to, start) = spring else { return }
        let omega = 2 * Double.pi / 0.45
        let t = Date().timeIntervalSince(start)
        let k = 1 - exp(-omega * t) * (1 + omega * t)
        guard t < 0.8, abs(to - from) * (1 - k) > 0.5 else {
            popover.contentSize.height = to
            popover.animates = true
            timer?.invalidate()
            spring = nil
            return
        }
        popover.contentSize.height = (from + (to - from) * k).rounded()
    }
}
