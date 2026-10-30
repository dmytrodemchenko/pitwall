import Foundation

struct ModelPrice: Codable, Equatable {
    let input, output, cacheRead, cacheWrite5m, cacheWrite1h: Double

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read", cacheWrite5m = "cache_write_5m", cacheWrite1h = "cache_write_1h"
    }

    func cost(_ t: TokenUsage) -> Double {
        (Double(t.input) * input + Double(t.output) * output + Double(t.cacheRead) * cacheRead
            + Double(t.cacheWrite5m) * cacheWrite5m + Double(t.cacheWrite1h) * cacheWrite1h) / 1_000_000
    }
}

struct PriceTable {
    let prices: [String: ModelPrice]

    func price(for model: String) -> ModelPrice? {
        prices.filter { model.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }

    func cost(of entries: [UsageEntry]) -> Double? {
        var sum = 0.0
        for e in entries where e.tokens.total > 0 {
            guard let p = price(for: e.model) else { return nil }
            sum += p.cost(e.tokens)
        }
        return sum
    }

    static func decode(_ data: Data) -> PriceTable? {
        (try? JSONDecoder().decode([String: ModelPrice].self, from: data)).map(PriceTable.init)
    }

    static func load(userFile: URL, defaultFile: URL?) -> PriceTable {
        ConfigFile.load(userFile: userFile, defaultFile: defaultFile, decode: decode) ?? PriceTable(prices: [:])
    }
}
