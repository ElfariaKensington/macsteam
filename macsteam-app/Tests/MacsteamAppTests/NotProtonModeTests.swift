import XCTest
@testable import MacsteamApp

final class NotProtonModeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.macsteam.tests.notproton.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultsOn() {
        XCTAssertTrue(NotProtonMode.isEnabled(defaults: defaults))
    }

    func testToggleOffAndOn() {
        NotProtonMode.setEnabled(false, defaults: defaults)
        XCTAssertFalse(NotProtonMode.isEnabled(defaults: defaults))
        NotProtonMode.setEnabled(true, defaults: defaults)
        XCTAssertTrue(NotProtonMode.isEnabled(defaults: defaults))
    }
}
