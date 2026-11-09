import XCTest
@testable import MacsteamApp

final class UpdateModeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.macsteam.tests.updates.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultsToAllowed() {
        XCTAssertTrue(UpdateMode.allowsUpdates(defaults: defaults))
    }

    func testToggleBlockAndAllow() {
        UpdateMode.setAllowsUpdates(false, defaults: defaults)
        XCTAssertFalse(UpdateMode.allowsUpdates(defaults: defaults))
        UpdateMode.setAllowsUpdates(true, defaults: defaults)
        XCTAssertTrue(UpdateMode.allowsUpdates(defaults: defaults))
    }
}
