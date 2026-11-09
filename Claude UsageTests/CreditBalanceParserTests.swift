import XCTest
@testable import Claude_Usage

final class CreditBalanceParserTests: XCTestCase {

    /// Example from Meshy's docs (GET /openapi/v1/balance).
    func testMeshyDocumentedExample() {
        let json: [String: Any] = ["balance": 1000, "monthly_credits": 600, "permanent_credits": 400, "monthly_resets_at": 1793491200000]
        let balance = CreditBalanceParser.parseMeshy(json)
        XCTAssertEqual(balance?.credits, 1000)
        XCTAssertEqual(balance?.monthlyResetsAt, Date(timeIntervalSince1970: 1_793_491_200))
    }

    func testMeshyWithoutRefill() {
        let balance = CreditBalanceParser.parseMeshy(["balance": 25, "monthly_resets_at": NSNull()])
        XCTAssertEqual(balance?.credits, 25)
        XCTAssertNil(balance?.monthlyResetsAt)
    }

    /// Example from Tripo's docs (GET /v3/account/balance).
    func testTripoDocumentedExample() {
        let json: [String: Any] = ["code": 0, "data": ["balance": 10000.00, "frozen": 200.00]]
        XCTAssertEqual(CreditBalanceParser.parseTripo(json), .init(credits: 10000, reserved: 200))
    }

    func testTripoErrorCode() {
        XCTAssertNil(CreditBalanceParser.parseTripo(["code": 2001, "message": "invalid"]))
    }

    func testCreditUsageMapping() {
        let usage = CreditUsage.mapToUsage(.init(credits: 0, reserved: 0))
        XCTAssertTrue(AccountUsage.isCredits(usage))
        XCTAssertTrue(AccountUsage.isOutOfBalance(usage))
    }
}
