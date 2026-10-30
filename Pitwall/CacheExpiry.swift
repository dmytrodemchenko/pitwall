import Foundation

enum CacheExpiry {
    static let lead: TimeInterval = 2 * 60
    static let minCostKey = "cacheWarnMinCost", defaultMinCost = 0.5

    static func minCost(_ d: UserDefaults = .standard) -> Double {
        d.object(forKey: minCostKey) == nil ? defaultMinCost : d.double(forKey: minCostKey)
    }

    static func ttl(_ entries: [UsageEntry]) -> TimeInterval {
        let write = entries.filter { $0.tokens.cacheWrite5m + $0.tokens.cacheWrite1h > 0 }.max { $0.timestamp < $1.timestamp }
        return (write?.tokens.cacheWrite1h ?? 0) > 0 ? 3600 : 300
    }

    static func extraCost(_ context: ContextUsage, ttl: TimeInterval, prices: PriceTable) -> Double? {
        guard let p = prices.price(for: context.model) else { return nil }
        return Double(context.tokens) * ((ttl > 300 ? p.cacheWrite1h : p.cacheWrite5m) - p.cacheRead) / 1_000_000
    }

    static func message(project: String, left: TimeInterval, extra: Double, estimate: Bool) -> String {
        let minutes = max(1, Int((left / 60).rounded()))
        return "\(project): prompt cache expires in \(minutes) min\n"
            + "A message after that costs \(estimate ? "≈ " : "")\(String(format: "$%.2f", extra)) more"
    }
}
