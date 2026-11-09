import XCTest
@testable import MacsteamApp

final class LuaToolsUsageTests: XCTestCase {
    func testUsageRemaining() {
        XCTAssertEqual(LuaToolsUsage(used: 3, limit: 25).remaining, 22)
        XCTAssertEqual(LuaToolsUsage(used: 25, limit: 25).remaining, 0)
        XCTAssertEqual(LuaToolsUsage(used: 30, limit: 25).remaining, 0)
    }

    func testContentRangeParsing() {
        XCTAssertEqual(LuaToolsGamesClient.usageCount(fromContentRange: "0-24/25"), 25)
        XCTAssertEqual(LuaToolsGamesClient.usageCount(fromContentRange: "*/0"), 0)
        XCTAssertNil(LuaToolsGamesClient.usageCount(fromContentRange: nil))
        XCTAssertNil(LuaToolsGamesClient.usageCount(fromContentRange: "garbage"))
    }
}
