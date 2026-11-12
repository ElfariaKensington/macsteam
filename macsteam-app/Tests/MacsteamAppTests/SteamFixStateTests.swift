import XCTest
import Foundation
@testable import MacsteamApp

/// What a fix looks like after the game changes underneath it: deleted, updated, read-only.
final class SteamFixStateTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fix-state-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            // Restore permissions so cleanup works after the read-only test.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// A game folder with `Game.dll` and `data.bin`, and a fix ZIP that replaces Game.dll and
    /// adds online.dll and sub/x.ini.
    private func fixture() throws -> (game: URL, zip: Data) {
        let root = try scratch()
        let game = root.appendingPathComponent("Game")
        try write("original game dll", game.appendingPathComponent("Game.dll"))
        try write("game data", game.appendingPathComponent("data.bin"))
        let src = root.appendingPathComponent("zipsrc")
        try write("fixed dll", src.appendingPathComponent("Game.dll"))
        try write("online dll", src.appendingPathComponent("online.dll"))
        try write("[net]", src.appendingPathComponent("sub/x.ini"))
        let archive = root.appendingPathComponent("fix.zip")
        let result = Subprocess.run("/usr/bin/ditto", ["-c", "-k", src.path, archive.path])
        XCTAssertEqual(result.code, 0)
        return (game, try Data(contentsOf: archive))
    }

    private func apply(_ f: (game: URL, zip: Data)) throws {
        _ = try SteamFixInstaller.apply(zipData: f.zip, appID: 1, fixID: "fix-1", installDir: f.game)
    }

    func testInstalledFixIsListedAsIntact() throws {
        let f = try fixture()
        try apply(f)
        let applied = SteamFixInstaller.appliedFixes(installDir: f.game)
        XCTAssertEqual(applied.map(\.fixID), ["fix-1"])
        XCTAssertEqual(applied.first?.health, .intact)
        XCTAssertEqual(applied.first?.added, 2)
        XCTAssertEqual(applied.first?.modified, 1)
    }

    func testDeletedGameFilesDropTheStaleUndo() throws {
        let f = try fixture()
        try apply(f)
        // The user removes the game's files by hand but the folder (and .macsteam-fix) stays.
        for name in ["Game.dll", "online.dll", "sub", "data.bin"] {
            try FileManager.default.removeItem(at: f.game.appendingPathComponent(name))
        }
        XCTAssertTrue(SteamFixInstaller.appliedFixes(installDir: f.game).isEmpty,
                      "no recorded file exists, so there is nothing to undo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.game.appendingPathComponent(".macsteam-fix").path),
                       "the stale record and backups are cleaned up")
    }

    func testGameUpdateOverwritingADllIsDriftNotAnError() throws {
        let f = try fixture()
        try apply(f)
        try write("game update dll", f.game.appendingPathComponent("Game.dll"))   // update replaced it
        let applied = SteamFixInstaller.appliedFixes(installDir: f.game)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.health, .drifted(changed: ["Game.dll"], missing: []))
        // Strict undo still refuses, with the file named...
        XCTAssertThrowsError(try SteamFixInstaller.revert(installDir: f.game, fixID: "fix-1")) { error in
            guard case SteamFixInstallError.modifiedSinceApply(let paths) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(paths, ["Game.dll"])
        }
        // ...but the safe undo removes what is still ours, keeps the game's updated DLL, and
        // clears the record.
        let result = try SteamFixInstaller.revertSafely(installDir: f.game, fixID: "fix-1")
        XCTAssertEqual(result.skipped, ["Game.dll"])
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(read(f.game.appendingPathComponent("Game.dll")), "game update dll")
        XCTAssertNil(read(f.game.appendingPathComponent("online.dll")))
        XCTAssertTrue(SteamFixInstaller.appliedFixes(installDir: f.game).isEmpty)
    }

    func testReinstallAfterDriftKeepsTheOriginalBackupSoUndoRestoresTheGame() throws {
        let f = try fixture()
        try apply(f)
        try write("game update dll", f.game.appendingPathComponent("Game.dll"))
        try FileManager.default.removeItem(at: f.game.appendingPathComponent("online.dll"))   // also deleted
        try apply(f)                                                                      // Reinstall
        XCTAssertEqual(SteamFixInstaller.appliedFixes(installDir: f.game).first?.health, .intact)
        XCTAssertEqual(read(f.game.appendingPathComponent("Game.dll")), "fixed dll")
        XCTAssertEqual(read(f.game.appendingPathComponent("online.dll")), "online dll")
        let result = try SteamFixInstaller.revert(installDir: f.game, fixID: "fix-1")
        XCTAssertEqual(result.restored, 1)
        XCTAssertEqual(result.removed, 2, "files the first install added are still removed, not 'restored'")
        XCTAssertEqual(read(f.game.appendingPathComponent("Game.dll")), "original game dll")
        XCTAssertNil(read(f.game.appendingPathComponent("online.dll")))
        XCTAssertEqual(read(f.game.appendingPathComponent("data.bin")), "game data")
    }

    func testSafeUndoDoesNotResurrectFilesTheUserDeleted() throws {
        let f = try fixture()
        try apply(f)
        try FileManager.default.removeItem(at: f.game.appendingPathComponent("Game.dll"))
        _ = try SteamFixInstaller.revertSafely(installDir: f.game, fixID: "fix-1")
        XCTAssertNil(read(f.game.appendingPathComponent("Game.dll")))
    }

    func testReadOnlyGameFolderReportsAPermissionProblemBeforeAnythingChanges() throws {
        let f = try fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.game.path)
        XCTAssertThrowsError(try SteamFixInstaller.ensureWritable(installDir: f.game)) { error in
            guard case SteamFixInstallError.permissionDenied = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try apply(f)) { error in
            guard case SteamFixInstallError.permissionDenied = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(read(f.game.appendingPathComponent("Game.dll")), "original game dll")
    }

    func testPermissionErrorsAreRecognised() {
        XCTAssertTrue(SteamFixInstaller.isPermissionError(CocoaError(.fileWriteNoPermission)))
        XCTAssertTrue(SteamFixInstaller.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertTrue(SteamFixInstaller.isPermissionError(NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])))
        XCTAssertFalse(SteamFixInstaller.isPermissionError(CocoaError(.fileNoSuchFile)))
    }

    func testFailedInstallRestoresTheGameFolder() throws {
        let f = try fixture()
        // A file where the fix wants a directory makes the install fail part-way.
        try FileManager.default.removeItem(at: f.game.appendingPathComponent("Game.dll"))
        try write("original game dll", f.game.appendingPathComponent("Game.dll"))
        try write("blocker", f.game.appendingPathComponent("sub"))
        XCTAssertThrowsError(try apply(f))
        XCTAssertEqual(read(f.game.appendingPathComponent("Game.dll")), "original game dll")
        XCTAssertNil(read(f.game.appendingPathComponent("online.dll")))
        XCTAssertEqual(read(f.game.appendingPathComponent("sub")), "blocker")
    }

    func testPermissionGuidancePicksThePaneThatUnblocksTheFolder() {
        let home = "/Users/me"
        typealias G = FileAccessGuidance
        XCTAssertEqual(G.pane(forPath: "/Volumes/Games/steamapps/common/X", home: home), .filesAndFolders)
        XCTAssertEqual(G.pane(forPath: "/Users/me/Downloads/Games/X", home: home), .filesAndFolders)
        XCTAssertEqual(G.pane(forPath: "/Users/me/Library/Application Support/Steam/steamapps/common/X.app/Contents", home: home), .appBundles)
        XCTAssertEqual(G.pane(forPath: "/Users/me/Library/Application Support/Steam/steamapps/common/X", home: home), .fullDiskAccess)
        XCTAssertTrue(G.explanation(forPath: "/Volumes/Games/X").contains("Files & Folders"))
        XCTAssertEqual(G.Pane.fullDiskAccess.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
