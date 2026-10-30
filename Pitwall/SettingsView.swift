import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let hotKey: HotKey
    @AppStorage(SessionActions.ideCommandKey) private var ideCommand = SessionActions.defaultIDECommand
    @AppStorage(SessionActions.terminalKey) private var terminal = SessionActions().terminalForNewTabs
    @AppStorage(ContextLevel.warnKey) private var contextWarn = ContextLevel.defaultWarn
    @AppStorage(ContextLevel.alertKey) private var contextAlert = ContextLevel.defaultAlert
    @AppStorage(CacheRatio.warnKey) private var cacheWarn = CacheRatio.defaultWarn
    @AppStorage(CacheExpiry.minCostKey) private var cacheMinCost = CacheExpiry.defaultMinCost
    @AppStorage(BudgetSettings.modeKey) private var billing = BillingMode.api
    @AppStorage(BudgetSettings.dailyBudgetKey) private var dailyBudget = 0.0
    @AppStorage(BudgetSettings.windowLimitKey) private var windowLimit = 0
    @AppStorage(Verifier.patternKey) private var failPattern = Verifier.defaultPattern
    @AppStorage(GateRun.limitKey) private var gateLimit = GateRun.defaultLimitMinutes

    var body: some View {
        Form {
            Section {
                LoginItemToggle()
                HotKeyRecorder(hotKey: hotKey)
            }
            Section {
                TextField("IDE command", text: $ideCommand, prompt: Text(SessionActions.defaultIDECommand))
                Text("“Open in IDE” runs this in a login shell with the project folder as its argument, e.g. `webstorm`, `code`, `idea`, `cursor`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("New sessions open in", selection: $terminal) {
                    Text("iTerm2").tag(TerminalFocus.iTerm)
                    Text("Terminal").tag(TerminalFocus.terminal)
                }
                Text("Used for New session, and for Resume when the session's own terminal can't be scripted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Context usage") {
                Stepper("Yellow from \(Int(contextWarn))%", value: $contextWarn, in: 10...(contextAlert - 5), step: 5)
                Stepper("Red and a notification above \(Int(contextAlert))%", value: $contextAlert,
                        in: (contextWarn + 5)...99, step: 1)
                Text("Context windows per model are in ~/.claude-monitor/context.json (default 200 000 tokens).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Budget") {
                Picker("Billing mode", selection: $billing) {
                    Text("API").tag(BillingMode.api)
                    Text("Subscription").tag(BillingMode.subscription)
                }
                .pickerStyle(.segmented)
                if billing == .api {
                    TextField("Daily budget (USD)", value: $dailyBudget, format: .number.precision(.fractionLength(0...2)),
                              prompt: Text("not set"))
                    Text("Shows today's cost against it, and notifies at 80% and 100% (once a day each). 0 turns it off.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Tokens per 5 hours", value: $windowLimit, format: .number, prompt: Text("not set"))
                    Text("An estimate. Counts input, output and cache-write tokens from your transcripts in a rolling "
                         + "5-hour window; cache reads aren't counted. Anthropic doesn't publish exact limits, so set a "
                         + "value from your own experience. Notifies at 80%. 0 turns it off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Cache") {
                Stepper("Warn when the cache hit ratio stays below \(Int(cacheWarn))% for 10 min", value: $cacheWarn,
                        in: 5...95, step: 5)
                TextField("Expiry warning from (USD)", value: $cacheMinCost,
                          format: .number.precision(.fractionLength(0...2)), prompt: Text("off"))
                Text("When a session waits for you, its prompt cache expires after 5 min (or 1 h). Notifies 2 min before, "
                     + "if your next message would then cost at least this much more. 0 turns it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Pipeline") {
                Stepper("Gate time turns yellow after \(Int(gateLimit)) min", value: $gateLimit, in: 1...120)
                TextField("Verifier failure pattern", text: $failPattern, prompt: Text(Verifier.defaultPattern))
                Text(Verifier.isValid(failPattern) || failPattern.isEmpty
                     ? "A run fails when the last line of the verifier's report matches this (regular expression, any case)."
                     : "Not a valid regular expression: it is matched as plain text.")
                    .font(.caption)
                    .foregroundStyle(Verifier.isValid(failPattern) || failPattern.isEmpty ? Color.secondary : Color(.waiting))
            }
            Section {
                Button("Open data folder (prices.json, events.jsonl)") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-monitor"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LoginItemToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Start at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: set))
        if status == .requiresApproval {
            HStack {
                Text("Waiting for approval in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
            }
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color(.failure))
        }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't \(on ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

private struct HotKeyRecorder: View {
    let hotKey: HotKey
    @State private var recording = false
    @State private var error: String?
    @State private var monitor: Any?
    @State private var display = ""

    var body: some View {
        LabeledContent("Open and close Pitwall") {
            Button(recording ? "Type a shortcut…" : display) { recording ? stop() : start() }
                .monospaced()
                .frame(minWidth: 130)
                .accessibilityHint(recording ? "Type the new shortcut, or Escape to cancel" : "Click to record a new shortcut")
        }
        .onAppear { display = (hotKey.combo ?? hotKey.saved).display }
        .onDisappear(perform: stop)
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color(.failure))
        }
    }

    private func start() {
        error = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
                stop()
            } else if let combo = KeyCombo(event: event) {
                do {
                    try hotKey.change(to: combo)
                    display = combo.display
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                stop()
            } else {
                error = "Use ⌘, ⌥ or ⌃ with a key."
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

#Preview { SettingsView(hotKey: HotKey()) }
