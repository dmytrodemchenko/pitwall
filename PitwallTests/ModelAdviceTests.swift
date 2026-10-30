import SwiftData
import XCTest
@testable import Pitwall

final class ModelAdviceTests: XCTestCase {
    private let prices = PriceTable(prices: [
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.1, cacheWrite5m: 2.5, cacheWrite1h: 4),
        "claude-sonnet-4": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6),
        "claude-haiku-5-5": ModelPrice(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.2),
    ])

    private func item(_ agent: String?, _ model: String, session: String, at minute: Double, output: Int = 100_000) -> UsageItem {
        UsageItem(project: "shop", session: session,
                  entry: UsageEntry(model: model, timestamp: t0 + minute * 60, tokens: TokenUsage(output: output)), agent: agent)
    }

    private func run(_ gate: String, session: String, from: Double, to: Double, verdict: String? = nil) -> GateRunItem {
        GateRunItem(session: session, gate: gate, start: t0 + from * 60, end: t0 + to * 60, verdict: verdict)
    }

    func testNamesAndTheTierBelow() {
        XCTAssertEqual(ModelAdvice.name("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelAdvice.name("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelAdvice.name("claude-sonnet-4"), "Sonnet 4")
        XCTAssertEqual(ModelAdvice.cheaper(than: "claude-opus-4-8", in: prices), "claude-sonnet-5-5")
        XCTAssertEqual(ModelAdvice.cheaper(than: "claude-sonnet-5-5", in: prices), "claude-haiku-5-5")
        XCTAssertEqual(ModelAdvice.cheaper(than: "claude-fable-5-1", in: prices), "claude-opus-5-5")
        XCTAssertNil(ModelAdvice.cheaper(than: "claude-haiku-5-5", in: prices))
    }

    /// Per pipeline gate: cost by model, what the same tokens cost one tier down, and the verifier verdict that followed each run.
    func testCostOnTheTierBelowAndTheVerdictAfterEachRun() throws {
        let items = [
            item("developer", "claude-opus-5-5", session: "a", at: 1), item("developer", "claude-opus-5-5", session: "b", at: 1),
            item("developer", "claude-sonnet-5-5", session: "c", at: 1),
            item("verifier", "claude-opus-5-5", session: "a", at: 6, output: 10_000),
            item(nil, "claude-opus-5-5", session: "a", at: 3), // the main agent: not a gate
            item("Explore", "claude-opus-5-5", session: "a", at: 3), // built in: not on the pipeline
        ]
        let runs = [
            run("developer", session: "a", from: 0, to: 2), run("verifier", session: "a", from: 5, to: 7, verdict: "fail"),
            run("developer", session: "b", from: 0, to: 2), // no verifier after it
            run("developer", session: "c", from: 0, to: 2), run("verifier", session: "c", from: 5, to: 7, verdict: "pass"),
            run("developer", session: "d", from: 0, to: 2), // no usage: model unknown
        ]
        let advice = ModelAdvice.advise(items: items, runs: runs, prices: prices, pattern: Verifier.defaultPattern)
        XCTAssertEqual(advice.map(\.gate), ["developer", "verifier"])
        let dev = advice[0]
        XCTAssertEqual(dev.models.map(\.model), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(dev.models.map(\.runs), [2, 1])
        XCTAssertEqual(dev.models.map(\.verifier), [.init(runs: 1, failures: 1), .init(runs: 1, failures: 0)])
        XCTAssertEqual(dev.cost, 2 + 2 + 1, accuracy: 1e-9)
        XCTAssertEqual(dev.cheaper, "claude-sonnet-5-5")
        XCTAssertEqual(try XCTUnwrap(dev.savings), 2, accuracy: 1e-9) // the Opus tokens on Sonnet; the Sonnet ones stay
        XCTAssertEqual(advice[1].models.first?.verifier, .init(runs: 1, failures: 1), "the verifier's own verdict")
    }

    /// Usage from a subagent transcript carries the agent type from its .meta.json; old rows are tagged once.
    func testSubagentUsageIsTaggedWithTheAgent() async throws {
        let root = tempDir(), session = root.appending(path: "p/s1"), sub = session.appending(path: "subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
        func line(_ id: String) -> String {
            #"{"timestamp":"\#(ts)","sessionId":"s1","cwd":"/x/shop","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2}}}"# + "\n"
        }
        try line("m1").write(to: root.appending(path: "p/s1.jsonl"), atomically: true, encoding: .utf8)
        try line("m2").write(to: sub.appending(path: "agent-1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"developer"}"#.write(to: sub.appending(path: "agent-1.meta.json"), atomically: true, encoding: .utf8)
        let container = try AnalyticsStore.container(inMemory: true)
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "advice-\(UUID())")!
        // Rows imported before agents were tagged: same message ids, no agent.
        let ctx = ModelContext(container)
        ctx.insert(UsageRow(try XCTUnwrap(UsageRecord.parse(Data(line("m2").utf8))), project: "shop"))
        try ctx.save()
        defaults.set(Date(), forKey: AnalyticsStore.importedKey)

        let store = AnalyticsStore(container: container)
        await store.importTranscripts(root: root, events: root.appending(path: "none.jsonl"), defaults: defaults)
        let items = await store.items(since: Date() - 3600)
        XCTAssertEqual(items.count, 1, "nothing new: the main transcript is older than the last import")
        XCTAssertEqual(items.map(\.agent), ["developer"])
        XCTAssertTrue(defaults.bool(forKey: AnalyticsStore.agentsKey))
    }
}
