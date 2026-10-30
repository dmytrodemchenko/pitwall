import Foundation

struct ModelAdvice: Identifiable, Equatable {
    struct Model: Equatable {
        let model: String
        var runs = 0
        var cost = 0.0
        var verifier = ConfigImpact.Side()
    }

    static let tiers = ["haiku", "sonnet", "opus", "fable|mythos"]

    let gate: String
    let models: [Model]
    let cheaper: String?
    let cheaperCost: Double?

    var id: String { gate }
    var cost: Double { models.reduce(0) { $0 + $1.cost } }
    var savings: Double? { cheaperCost.map { cost - $0 } }

    static func name(_ model: String) -> String {
        let parts = model.split(separator: "-").dropFirst(model.hasPrefix("claude-") ? 1 : 0)
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return ([family.capitalized] + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }

    static func cheaper(than model: String, in prices: PriceTable) -> String? {
        guard let tier = tiers.firstIndex(where: { model.range(of: $0, options: .regularExpression) != nil }), tier > 0 else { return nil }
        return prices.prices.keys.filter { $0.range(of: tiers[tier - 1], options: .regularExpression) != nil }.max()
    }

    static func advise(items: [UsageItem], runs: [GateRunItem], prices: PriceTable, pattern: String) -> [ModelAdvice] {
        let verifierRuns = Dictionary(grouping: runs.filter { $0.gate == "verifier" }, by: \.session)
        let byGate = Dictionary(grouping: items.filter { $0.agent.map(GateRun.isPipeline) == true }) { $0.agent! }
        return byGate.compactMap { gate, items -> ModelAdvice? in
            var models: [String: Model] = [:]
            for i in items {
                models[i.entry.model, default: Model(model: i.entry.model)].cost += prices.price(for: i.entry.model)?.cost(i.entry.tokens) ?? 0
            }
            let bySession = Dictionary(grouping: items, by: \.session)
            for run in runs where run.gate == gate {
                let own = (bySession[run.session] ?? []).filter { $0.entry.timestamp >= run.start - 5 && $0.entry.timestamp <= run.end + 5 }
                guard let model = Dictionary(grouping: own, by: \.entry.model)
                    .max(by: { $0.value.count < $1.value.count })?.key else { continue }
                models[model]?.runs += 1
                let next = (verifierRuns[run.session] ?? []).filter { $0.end >= run.end - 1 }.min { $0.end < $1.end }
                if let next, let failed = Verifier.failed(message: next.lastMessage, verdict: next.verdict, pattern: pattern) {
                    models[model]?.verifier.runs += 1
                    if failed { models[model]?.verifier.failures += 1 }
                }
            }
            let sorted = models.values.sorted { $0.cost > $1.cost }
            guard let main = sorted.first, main.cost > 0 else { return nil }
            let cheaper = cheaper(than: main.model, in: prices)
            let cheaperCost = cheaper.flatMap { prices.price(for: $0) }.map { p in
                items.reduce(0) { sum, i in
                    sum + (i.entry.model == main.model ? p.cost(i.entry.tokens) : prices.price(for: i.entry.model)?.cost(i.entry.tokens) ?? 0)
                }
            }
            return ModelAdvice(gate: gate, models: sorted, cheaper: cheaper, cheaperCost: cheaperCost)
        }
        .sorted { $0.savings ?? 0 != $1.savings ?? 0 ? $0.savings ?? 0 > $1.savings ?? 0 : $0.gate < $1.gate }
    }
}
