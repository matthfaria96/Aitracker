import XCTest
@testable import Claude_Usage

final class DeepSeekBalanceParserTests: XCTestCase {

    /// Example from DeepSeek's API docs (GET /user/balance).
    func testDocumentedExample() {
        let json: [String: Any] = [
            "is_available": true,
            "balance_infos": [["currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"]],
        ]
        let balance = DeepSeekBalanceParser.parse(json)
        XCTAssertEqual(balance, .init(isAvailable: true, currency: "CNY", total: 110, granted: 10, toppedUp: 100))
    }

    func testPrefersUSD() {
        let json: [String: Any] = [
            "is_available": false,
            "balance_infos": [
                ["currency": "CNY", "total_balance": "5.00"],
                ["currency": "USD", "total_balance": "0.00"],
            ],
        ]
        let balance = DeepSeekBalanceParser.parse(json)
        XCTAssertEqual(balance?.currency, "USD")
        XCTAssertEqual(balance?.isAvailable, false)
    }

    func testMapsToBalanceOnlyUsage() {
        let usage = DeepSeekUsageProvider.mapToUsage(.init(isAvailable: true, currency: "USD", total: 12.5, granted: 0, toppedUp: 12.5))
        XCTAssertEqual(usage.creditsBalance, 12.5)
        XCTAssertEqual(usage.costCurrency, "USD")
        XCTAssertFalse(AccountUsage.isOutOfBalance(usage))
        XCTAssertFalse(AccountUsage.hasWeeklyLimit(usage))
    }

    func testEmptyResponseIsNil() {
        XCTAssertNil(DeepSeekBalanceParser.parse(["is_available": true, "balance_infos": []]))
    }
}
