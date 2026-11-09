import XCTest
@testable import Claude_Usage

/// The Kimi /usages schema is undocumented; both known shapes must parse.
final class KimiUsageParserTests: XCTestCase {

    func testShapeWithUsagesRatios() {
        let json: [String: Any] = ["usages": [
            "limit_5h": ["used_ratio": 0.42, "reset_time": "2026-11-09T05:24:18.443553353Z"],
            "limit_7d": ["used_ratio": 0.1, "reset_time": "2026-11-12T00:00:00Z"],
        ]]
        let result = KimiUsageParser.parse(json)
        XCTAssertEqual(result.session?.percent ?? -1, 42, accuracy: 0.001)
        XCTAssertEqual(result.weekly?.percent ?? -1, 10, accuracy: 0.001)
        XCTAssertNotNil(result.session?.resetsAt)
        XCTAssertNotNil(result.weekly?.resetsAt)
    }

    func testShapeWithLimitsArray() {
        let json: [String: Any] = [
            "usage": ["limit": 1000, "remaining": 250, "resetTime": "2026-11-12T00:00:00Z"],
            "limits": [[
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": 200, "used": 50, "resetTime": "2026-11-09T05:00:00Z"],
            ]],
        ]
        let result = KimiUsageParser.parse(json)
        XCTAssertEqual(result.session?.percent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(result.weekly?.percent ?? -1, 75, accuracy: 0.001)
    }

    func testSessionOnlyPlan() {
        let json: [String: Any] = ["limits": [[
            "window": ["duration": 5, "timeUnit": "HOUR"],
            "detail": ["limit": 100, "used": 100],
        ]]]
        let result = KimiUsageParser.parse(json)
        XCTAssertEqual(result.session?.percent ?? -1, 100, accuracy: 0.001)
        XCTAssertNil(result.weekly)
    }

    func testNanosecondTimestamp() {
        XCTAssertNotNil(KimiUsageParser.parseDate("2025-12-23T05:24:18.443553353Z"))
        XCTAssertNotNil(KimiUsageParser.parseDate("2025-12-23T05:24:18Z"))
    }
}
