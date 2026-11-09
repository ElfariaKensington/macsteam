import XCTest
@testable import MacsteamApp

final class SteamLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsteam-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testResolvesInstallDirFromAppManifest() throws {
        let game = root.appendingPathComponent("steamapps/common/UNO", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("steamapps/appmanifest_470220.acf")
        try """
        "AppState"
        {
            "appid" "470220"
            "installdir" "UNO"
        }
        """.write(to: manifest, atomically: true, encoding: .utf8)

        XCTAssertEqual(SteamLibrary.installDir(appID: 470220, steamRoot: root)?.path,
                       game.path)
        XCTAssertNil(SteamLibrary.installDir(appID: 999, steamRoot: root))
    }

    func testResolvesInstallDirFromExtraLibraryFolder() throws {
        let extra = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsteam-extra-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extra) }
        let game = extra.appendingPathComponent("steamapps/common/Game Two", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try """
        "AppState"
        {
            "appid" "12345"
            "installdir" "Game Two"
        }
        """.write(to: extra.appendingPathComponent("steamapps/appmanifest_12345.acf"),
                  atomically: true, encoding: .utf8)

        let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        try FileManager.default.createDirectory(at: vdf.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try """
        "libraryfolders"
        {
            "0"
            {
                "path" "\(root.path)"
            }
            "1"
            {
                "path" "\(extra.path)"
            }
        }
        """.write(to: vdf, atomically: true, encoding: .utf8)

        XCTAssertEqual(SteamLibrary.installDir(appID: 12345, steamRoot: root)?.path,
                       game.path)
    }

    func testMissingInstallDirReturnsNil() {
        XCTAssertNil(SteamLibrary.installDir(appID: 470220, steamRoot: root))
    }
}

final class SteamFixInstallerTests: XCTestCase {
    private var game: URL!
    private var work: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        work = fm.temporaryDirectory
            .appendingPathComponent("macsteam-fixapply-\(UUID().uuidString)", isDirectory: true)
        game = work.appendingPathComponent("Game", isDirectory: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    func testApplyBacksUpAndReplacesFiles() throws {
        let original = game.appendingPathComponent("Data/config.ini")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "original".write(to: original, atomically: true, encoding: .utf8)

        let zip = try makeZip([
            "Data/config.ini": "patched",
            "bin/new.dll": "added",
        ])

        let result = try SteamFixInstaller.apply(zipData: zip,
                                                 appID: 470220,
                                                 fixID: "fix-1",
                                                 installDir: game)
        XCTAssertEqual(result.modified, 1)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "patched")
        let added = game.appendingPathComponent("bin/new.dll")
        XCTAssertEqual(try String(contentsOf: added, encoding: .utf8), "added")

        let backup = result.backupDir.appendingPathComponent("Data/config.ini.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.backupDir.appendingPathComponent("record.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: result.backupDir.appendingPathComponent("bin/new.dll.bak").path))
    }

    func testApplyKeepsFirstBackupWhenRunTwice() throws {
        let original = game.appendingPathComponent("config.ini")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        let zip = try makeZip(["config.ini": "patched"])

        _ = try SteamFixInstaller.apply(zipData: zip, appID: 1, fixID: "fix-1",
                                        installDir: game)
        try "patched twice".write(to: original, atomically: true, encoding: .utf8)
        _ = try SteamFixInstaller.apply(zipData: zip, appID: 1, fixID: "fix-1",
                                        installDir: game)

        let backup = game.appendingPathComponent(".macsteam-fix/fix-1/config.ini.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "patched")
    }

    func testApplySanitizesFixID() throws {
        let zip = try makeZip(["file.txt": "x"])
        let result = try SteamFixInstaller.apply(zipData: zip, appID: 1,
                                                 fixID: "../evil", installDir: game)
        XCTAssertEqual(result.backupDir.lastPathComponent, ".._evil")
        XCTAssertTrue(result.backupDir.path.hasPrefix(
            game.appendingPathComponent(".macsteam-fix").path))
    }

    func testAppliedFixesAndRevertRestoreOriginals() throws {
        let original = game.appendingPathComponent("Data/config.ini")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "original".write(to: original, atomically: true, encoding: .utf8)
        let added = game.appendingPathComponent("bin/new.dll")

        let zip = try makeZip([
            "Data/config.ini": "patched",
            "bin/new.dll": "added",
        ])
        _ = try SteamFixInstaller.apply(zipData: zip, appID: 1, fixID: "fix-1",
                                        installDir: game)

        let applied = SteamFixInstaller.appliedFixes(installDir: game)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.fixID, "fix-1")
        XCTAssertEqual(applied.first?.modified, 1)
        XCTAssertEqual(applied.first?.added, 1)

        let result = try SteamFixInstaller.revert(installDir: game, fixID: "fix-1")
        XCTAssertEqual(result.restored, 1)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: added.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: game.appendingPathComponent(".macsteam-fix").path))
        XCTAssertTrue(SteamFixInstaller.appliedFixes(installDir: game).isEmpty)
    }

    func testRevertRefusesFileChangedAfterApply() throws {
        let original = game.appendingPathComponent("config.ini")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        let zip = try makeZip(["config.ini": "patched"])
        _ = try SteamFixInstaller.apply(zipData: zip, appID: 1, fixID: "fix-1",
                                        installDir: game)
        try "changed by game update".write(to: original, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SteamFixInstaller.revert(installDir: game, fixID: "fix-1")) { error in
            guard case SteamFixInstallError.modifiedSinceApply(let paths) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(paths, ["config.ini"])
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8),
                       "changed by game update")
        XCTAssertEqual(SteamFixInstaller.appliedFixes(installDir: game).count, 1)
    }

    func testRevertRefusesAddedFileChanged() throws {
        let original = game.appendingPathComponent("config.ini")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        let zip = try makeZip(["config.ini": "patched", "new.txt": "added"])
        _ = try SteamFixInstaller.apply(zipData: zip, appID: 1, fixID: "fix-1",
                                        installDir: game)
        let added = game.appendingPathComponent("new.txt")
        try "game wrote this".write(to: added, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SteamFixInstaller.revert(installDir: game, fixID: "fix-1")) { error in
            guard case SteamFixInstallError.modifiedSinceApply(let paths) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(paths, ["new.txt"])
        }
        XCTAssertEqual(try String(contentsOf: added, encoding: .utf8), "game wrote this")
        XCTAssertEqual(SteamFixInstaller.appliedFixes(installDir: game).count, 1)
    }

    func testRevertLegacyRecordWithoutHashes() throws {
        let original = game.appendingPathComponent("config.ini")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        let backupRoot = game.appendingPathComponent(".macsteam-fix/legacy",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot,
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original,
                                         to: backupRoot.appendingPathComponent(
                                            "config.ini.bak"))
        try "patched".write(to: original, atomically: true, encoding: .utf8)

        let record = """
        {
          "appid": 1,
          "fixid": "legacy",
          "appliedAt": "2026-01-01T00:00:00Z",
          "files": [
            {"path": "config.ini", "action": "modified",
             "backup": "\(backupRoot.appendingPathComponent("config.ini.bak").path)"}
          ]
        }
        """
        try record.write(to: backupRoot.appendingPathComponent("record.json"),
                         atomically: true, encoding: .utf8)

        let result = try SteamFixInstaller.revert(installDir: game, fixID: "legacy")
        XCTAssertEqual(result.restored, 1)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }

    func testApplyRejectsBadArchive() {
        XCTAssertThrowsError(try SteamFixInstaller.apply(
            zipData: Data("not a zip".utf8), appID: 1, fixID: "fix-1",
            installDir: game))
    }

    func testApplyRejectsArchiveWithNoFiles() throws {
        let zip = try makeZip([".DS_Store": "junk"])
        XCTAssertThrowsError(try SteamFixInstaller.apply(
            zipData: zip, appID: 1, fixID: "fix-1", installDir: game)) { error in
            guard case SteamFixInstallError.badArchive = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func makeZip(_ files: [String: String]) throws -> Data {
        let payload = work.appendingPathComponent("payload-\(UUID().uuidString)",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for (name, contents) in files {
            let file = payload.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        let zip = work.appendingPathComponent("fix-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zip.path, "."]
        process.currentDirectoryURL = payload
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: zip)
    }
}
