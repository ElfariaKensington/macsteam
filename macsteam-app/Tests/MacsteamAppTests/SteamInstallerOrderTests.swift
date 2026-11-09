import XCTest
@testable import MacsteamApp

final class SteamInstallerOrderTests: XCTestCase {
    func testMacSteamCompatibilityDylibLoadsBeforeNotProton() {
        let ours = "/Applications/Steam.app/Contents/MacOS/macsteam.dylib"
        let notProton = "/Applications/Steam.app/Contents/MacOS/notproton.dylib"
        let compat = "/Users/example/Library/Application Support/macsteam/notproton.dylib"
        let result = SteamInstaller.directInsertComponents(
            existing: [notProton, ours], ours: ours, compat: compat)
        XCTAssertEqual(result, [compat, notProton])
    }

    func testLauncherModeRemovesBothMacSteamCopies() {
        let ours = "/Applications/Steam.app/Contents/MacOS/macsteam.dylib"
        let notProton = "/Applications/Steam.app/Contents/MacOS/notproton.dylib"
        let compat = "/Users/example/Library/Application Support/macsteam/notproton.dylib"
        let result = SteamInstaller.launcherInsertComponents(
            existing: [notProton, ours, compat], ours: ours, compat: compat)
        XCTAssertEqual(result, [notProton])
    }

    func testDirectInsertDoesNotDuplicatePaths() {
        let compat = "/Users/example/Library/Application Support/macsteam/notproton.dylib"
        let other = "/Applications/Steam.app/Contents/MacOS/notproton.dylib"
        let result = SteamInstaller.directInsertComponents(
            existing: [compat, other], ours: "/Applications/Steam.app/Contents/MacOS/macsteam.dylib",
            compat: compat)
        XCTAssertEqual(result, [compat, other])
    }
}
