import XCTest
@testable import MacsteamApp

final class CloudErrorPolicyTests: XCTestCase {
    func testUnlockedGameWithFreeLicenseIsDisabled() {
        XCTAssertTrue(CloudErrorPolicy.shouldDisable(
            freeRemovableLicense: true, cloudEnabled: true, status: 5))
        XCTAssertTrue(CloudErrorPolicy.shouldDisable(
            freeRemovableLicense: true, cloudEnabled: true, status: 8))
    }

    func testOwnedGameKeepsNativeCloud() {
        XCTAssertFalse(CloudErrorPolicy.shouldDisable(
            freeRemovableLicense: false, cloudEnabled: true, status: 8))
    }

    func testAlreadyDisabledAppIsIgnored() {
        XCTAssertFalse(CloudErrorPolicy.shouldDisable(
            freeRemovableLicense: true, cloudEnabled: false, status: 1))
        XCTAssertFalse(CloudErrorPolicy.shouldDisable(
            freeRemovableLicense: true, cloudEnabled: true, status: 1))
    }

    func testHideCloudErrorsDefaultsOff() {
        XCTAssertFalse(MacsteamConfig.parse("HideWhatsNew: no\n").hideCloudErrors)
    }

    func testHideCloudErrorsParsesYes() {
        let cfg = MacsteamConfig.parse("HideCloudErrors: yes\nHideWhatsNew: yes\n")
        XCTAssertTrue(cfg.hideCloudErrors)
        XCTAssertEqual(cfg.extraTopLevelLines, ["HideCloudErrors: yes"])
    }

    func testHideCloudErrorsParsesNo() {
        XCTAssertFalse(MacsteamConfig.parse("HideCloudErrors: no\n").hideCloudErrors)
        XCTAssertFalse(MacsteamConfig.parse("HideCloudErrors: 0\n").hideCloudErrors)
    }
}
