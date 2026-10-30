import XCTest
@testable import Pitwall

@MainActor
final class BudgetTests: XCTestCase {
    private let prices = PriceTable(prices: ["m": ModelPrice(input: 10, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)])
    private let noon = Calendar.current.startOfDay(for: t0) + 12 * 3600

    private func use(_ at: Date, input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0) -> UsageEntry {
        UsageEntry(model: "m", timestamp: at, tokens: TokenUsage(input: input, output: output, cacheRead: read, cacheWrite5m: write))
    }

    func testCostTodayAndTheFiveHourWindow() throws {
        let entries = [use(noon - 13 * 3600, input: 1_000_000),         // yesterday: not today, not in the window
                       use(noon - 6 * 3600, input: 100_000),           // today, but outside the window
                       use(noon - 4 * 3600, input: 10, output: 5, read: 1_000_000, write: 20), // in: 35 (reads not counted)
                       use(noon - 4.5 * 3600, read: 500),              // cache reads only: not usage for the window
                       use(noon - 60, output: 100),
                       use(noon + 60, input: 999)]                     // future: ignored
        let s = BudgetStatus(entries: entries, prices: prices, now: noon)
        XCTAssertEqual(s.costToday, 1.0001, accuracy: 1e-9) // 100 010 input tokens × $10/M
        XCTAssertEqual(s.windowTokens, 135)
        XCTAssertEqual(s.windowOldest, noon - 4 * 3600)
        XCTAssertEqual(try XCTUnwrap(s.windowFreesAt).timeIntervalSince(noon), 3600) // leaves in 1 h
        XCTAssertNil(BudgetStatus(entries: [], prices: prices, now: noon).windowFreesAt)
        XCTAssertEqual(BudgetRow.remaining(3600 + 14 * 60 + 30), "1 h 14 min")
    }

    func testDailyBudgetAlertsOncePerDay() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        d.set(BillingMode.api.rawValue, forKey: BudgetSettings.modeKey)
        var sent: [String] = []
        let alerts = BudgetAlerts(defaults: d) { sent.append($0) }
        alerts.check(BudgetStatus(costToday: 5), now: noon) // no budget set: nothing
        d.set(10.0, forKey: BudgetSettings.dailyBudgetKey)
        alerts.check(BudgetStatus(costToday: 7.9), now: noon)
        XCTAssertEqual(sent.count, 0)
        alerts.check(BudgetStatus(costToday: 8), now: noon)
        alerts.check(BudgetStatus(costToday: 9), now: noon)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].hasPrefix("80%"))
        alerts.check(BudgetStatus(costToday: 10.5), now: noon)
        alerts.check(BudgetStatus(costToday: 12), now: noon)
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent[1].hasPrefix("Daily budget reached"))
        // The next day starts over; jumping straight past 100% sends one alert, not two.
        alerts.check(BudgetStatus(costToday: 11), now: noon + 86400)
        XCTAssertEqual(sent.count, 3)
        alerts.check(BudgetStatus(costToday: 11), now: noon + 86400)
        XCTAssertEqual(sent.count, 3)
    }

    func testWindowAlertAtEightyPercentRearmsBelow() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        d.set(BillingMode.subscription.rawValue, forKey: BudgetSettings.modeKey)
        d.set(1000, forKey: BudgetSettings.windowLimitKey)
        var sent: [String] = []
        let alerts = BudgetAlerts(defaults: d) { sent.append($0) }
        alerts.check(BudgetStatus(windowTokens: 700))
        alerts.check(BudgetStatus(windowTokens: 850))
        alerts.check(BudgetStatus(windowTokens: 990))
        XCTAssertEqual(sent, ["About 85% of your 5-hour token limit used (estimate)"])
        alerts.check(BudgetStatus(windowTokens: 300)) // old usage left the window
        alerts.check(BudgetStatus(windowTokens: 820))
        XCTAssertEqual(sent.count, 2)
    }

    func testAPIModeIsTheDefault() {
        XCTAssertEqual(BudgetSettings.mode(UserDefaults(suiteName: "test-\(UUID())")!), .api)
    }
}
