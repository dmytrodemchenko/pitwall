import Foundation

enum BillingMode: String, CaseIterable {
    case api, subscription
}

enum BudgetSettings {
    static let modeKey = "billingMode", dailyBudgetKey = "dailyBudgetUSD", windowLimitKey = "windowTokenLimit"
    static let window: TimeInterval = 5 * 3600

    static func mode(_ d: UserDefaults = .standard) -> BillingMode {
        d.string(forKey: modeKey).flatMap(BillingMode.init) ?? .api
    }
    static func dailyBudget(_ d: UserDefaults = .standard) -> Double { d.double(forKey: dailyBudgetKey) }
    static func windowLimit(_ d: UserDefaults = .standard) -> Int { d.integer(forKey: windowLimitKey) }
}

struct BudgetStatus: Equatable {
    var costToday: Double
    var windowTokens: Int
    var windowOldest: Date?

    init(costToday: Double = 0, windowTokens: Int = 0, windowOldest: Date? = nil) {
        self.costToday = costToday
        self.windowTokens = windowTokens
        self.windowOldest = windowOldest
    }

    init(entries: [UsageEntry], prices: PriceTable, now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        costToday = entries.filter { $0.timestamp >= today && $0.timestamp <= now }
            .reduce(0) { $0 + (prices.price(for: $1.model)?.cost($1.tokens) ?? 0) }
        let inWindow = entries.filter { $0.timestamp > now - BudgetSettings.window && $0.timestamp <= now }
            .filter { Self.counted($0.tokens) > 0 }
        windowTokens = inWindow.reduce(0) { $0 + Self.counted($1.tokens) }
        windowOldest = inWindow.map(\.timestamp).min()
    }

    static func counted(_ t: TokenUsage) -> Int { t.input + t.output + t.cacheWrite5m + t.cacheWrite1h }

    var windowFreesAt: Date? { windowOldest.map { $0 + BudgetSettings.window } }
}

final class BudgetAlerts {
    var defaults: UserDefaults
    private let notify: (String) -> Void

    init(defaults: UserDefaults = .standard, notify: @escaping (String) -> Void) {
        self.defaults = defaults
        self.notify = notify
    }

    func check(_ s: BudgetStatus, now: Date = Date(), calendar: Calendar = .current) {
        switch BudgetSettings.mode(defaults) {
        case .api:
            let budget = BudgetSettings.dailyBudget(defaults)
            guard budget > 0 else { return }
            let percent = s.costToday / budget * 100
            let day = Self.dayStamp(now, calendar)
            let saved = defaults.string(forKey: "budgetAlerts")?.split(separator: ":")
            var sent = saved?.first.map(String.init) == day ? Set(saved!.last!.split(separator: ",").map(String.init)) : []
            for level in [100, 80] where percent >= Double(level) && !sent.contains("\(level)") {
                sent.formUnion(["80", "\(level)"])
                notify(level == 100
                    ? "Daily budget reached: \(UsageText.cost(s.costToday)) of \(UsageText.cost(budget))"
                    : "80% of the daily budget used: \(UsageText.cost(s.costToday)) of \(UsageText.cost(budget))")
                break
            }
            defaults.set("\(day):\(sent.sorted().joined(separator: ","))", forKey: "budgetAlerts")
        case .subscription:
            let limit = BudgetSettings.windowLimit(defaults)
            guard limit > 0 else { return }
            let percent = Double(s.windowTokens) / Double(limit) * 100
            if percent < 80 {
                defaults.removeObject(forKey: "windowAlerted")
            } else if !defaults.bool(forKey: "windowAlerted") {
                defaults.set(true, forKey: "windowAlerted")
                notify("About \(Int(percent))% of your 5-hour token limit used (estimate)")
            }
        }
    }

    private static func dayStamp(_ d: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }
}
