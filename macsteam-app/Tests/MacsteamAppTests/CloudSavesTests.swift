import XCTest
@testable import MacsteamApp

final class CloudSavesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsteam-cloudtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLocalFileIsMirroredToSyncFolder() throws {
        let local = try localFile("save.dat", contents: Data("local".utf8))
        let sync = root.appendingPathComponent("cloud", isDirectory: true)
        let report = CloudSavesEngine.sync(steamRoot: steamRoot, syncRoot: sync, apps: [456])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.copiedToCloud, 1)
        XCTAssertEqual(try Data(contentsOf: cloudFile("save.dat", sync)), Data("local".utf8))
        XCTAssertEqual(local.lastPathComponent, "save.dat")

        XCTAssertEqual(report.games.count, 1)
        let game = try XCTUnwrap(report.games.first)
        XCTAssertEqual(game.appID, 456)
        XCTAssertEqual(game.files, 1)
        XCTAssertEqual(game.copiedToCloud, 1)
        XCTAssertTrue(game.isSuccess)
        XCTAssertEqual(game.statusText, "Synced · 1 file · 1 up")
    }

    func testGameStatusText() {
        var game = CloudSavesGameSync(appID: 1)
        game.files = 5
        XCTAssertEqual(game.statusText, "Up to date · 5 files")
        game.copiedToLocal = 2
        XCTAssertEqual(game.statusText, "Synced · 5 files · 2 down")
        game.conflicts = 1
        XCTAssertEqual(game.statusText,
                       "Synced · 5 files · 2 down · 1 conflict")
        game.errors = ["disk full"]
        XCTAssertEqual(game.statusText, "Failed · disk full")
        XCTAssertFalse(game.isSuccess)
    }

    func testReportMergesGamesAndNames() {
        var report = CloudSavesReport()
        report.mergeGames([
            CloudSavesGameSync(appID: 456, name: "", files: 3, copiedToCloud: 1),
        ])
        report.mergeGames([
            CloudSavesGameSync(appID: 456, name: "", files: 3, copiedToLocal: 2),
            CloudSavesGameSync(appID: 789, name: "", files: 1),
        ])
        XCTAssertEqual(report.games.map(\.appID), [456, 789])
        XCTAssertEqual(report.games[0].files, 3)
        XCTAssertEqual(report.games[0].copiedToCloud, 1)
        XCTAssertEqual(report.games[0].copiedToLocal, 2)

        report.applyNames([456: "Cult of the Lamb"])
        XCTAssertEqual(report.games[0].displayName, "Cult of the Lamb")
        XCTAssertEqual(report.games[1].displayName, "App 789")
    }

    func testCloudFileIsRestoredLocally() throws {
        let sync = root.appendingPathComponent("cloud", isDirectory: true)
        let cloud = cloudFile("save.dat", sync)
        try FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: cloud)

        let report = CloudSavesEngine.sync(steamRoot: steamRoot, syncRoot: sync, apps: [456])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.copiedToLocal, 1)
        let local = steamRoot.appendingPathComponent("userdata/123/456/remote/save.dat")
        XCTAssertEqual(try Data(contentsOf: local), Data("remote".utf8))
    }

    func testNewestCopyWinsAndOldVersionIsBackedUp() throws {
        let local = try localFile("save.dat", contents: Data("old-local".utf8))
        let sync = root.appendingPathComponent("cloud", isDirectory: true)
        let cloud = cloudFile("save.dat", sync)
        try FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("new-cloud".utf8).write(to: cloud)

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_700_001_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: local.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: cloud.path)

        let report = CloudSavesEngine.sync(steamRoot: steamRoot, syncRoot: sync, apps: [456])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.copiedToLocal, 1)
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(try Data(contentsOf: local), Data("new-cloud".utf8))
        let conflicts = sync.appendingPathComponent(".conflicts", isDirectory: true)
        let backups = try FileManager.default.subpathsOfDirectory(atPath: conflicts.path)
        XCTAssertTrue(backups.contains { $0.hasSuffix("save.dat") })
    }

    func testSyncReportSummaries() {
        var drive = CloudProviderSyncReport()
        XCTAssertEqual(drive.summary, "Drive: no files yet")
        drive.remoteFiles = 56
        XCTAssertEqual(drive.summary, "Drive: up to date · 56 files")
        drive.uploaded = 2
        drive.conflicts = 1
        drive.removed = 5
        XCTAssertEqual(drive.summary,
                       "Drive: 2 up · 0 down · 1 conflict · 5 removed · 56 files")

        var local = CloudSavesReport()
        local.copiedToCloud = 3
        local.removed = 2
        local.remoteSummary = drive.summary
        XCTAssertEqual(local.summary,
                       "Local: 3 up · 0 down · 2 removed · "
                       + "Drive: 2 up · 0 down · 1 conflict · 5 removed · 56 files")
    }

    func testOAuthLoopbackServerStarts() throws {
        let server = try OAuthLoopbackServer()
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)
    }

    func testOAuthLoopbackIgnoresNonCallbackRequests() async throws {
        let server = try OAuthLoopbackServer()
        defer { server.stop() }
        let task = Task { try await server.waitForCode(state: "state-xyz") }
        _ = try? await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/favicon.ico")!)
        _ = try? await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/callback?code=ok&state=state-xyz")!)
        let code = try await task.value
        XCTAssertEqual(code, "ok")
    }

    func testOAuthCallbackParsing() async throws {
        let server = try OAuthLoopbackServer()
        defer { server.stop() }
        let task = Task { try await server.waitForCode(state: "state-123") }
        let url = URL(string: "http://127.0.0.1:\(server.port)/callback?code=code-456&state=state-123")!
        _ = try? await URLSession.shared.data(from: url)
        let code = try await task.value
        XCTAssertEqual(code, "code-456")
    }

    func testSettingsDefaultToFolderAndSupportGoogleDrive() throws {
        let old = Data(#"{"enabled":true,"syncPath":"/tmp/saves"}"#.utf8)
        let decoded = try JSONDecoder().decode(CloudSavesSettings.self, from: old)
        XCTAssertEqual(decoded.provider, .folder)
        XCTAssertEqual(decoded.syncPath, "/tmp/saves")

        var settings = decoded
        settings.provider = .gdrive
        XCTAssertEqual(settings.expandedSyncURL, Paths.cloudSavesCacheDir)
        let roundTrip = try JSONDecoder().decode(
            CloudSavesSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.provider, .gdrive)
    }

    func testPausedAppsPersistAndLegacyProviderFallsBack() throws {
        var settings = CloudSavesSettings()
        settings.disabledApps = [100, 300]
        let roundTrip = try JSONDecoder().decode(
            CloudSavesSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.disabledApps, [100, 300])

        let legacy = try JSONDecoder().decode(
            CloudSavesSettings.self, from: Data(#"{"enabled":true,"provider":"onedrive"}"#.utf8))
        XCTAssertEqual(legacy.provider, .folder)
        XCTAssertTrue(legacy.disabledApps.isEmpty)
    }

    @MainActor
    func testPausedBaseGameAlsoPausesItsDLC() throws {
        let config = root.appendingPathComponent("config.yaml")
        try """
        Apps:
          - 100
          - 200  # DLC @100
          - 300
        """.write(to: config, atomically: true, encoding: .utf8)
        let store = ConfigStore(configFile: config,
                                backupDir: root.appendingPathComponent("backups"))
        store.load()
        let active = CloudSavesRunner.activeApps([100, 200, 300], store: store,
                                                 disabled: [100])
        XCTAssertEqual(active, [300])
    }

    func testUnmanagedAppIsIgnored() throws {
        _ = try localFile("save.dat", contents: Data("x".utf8))
        let sync = root.appendingPathComponent("cloud", isDirectory: true)
        let report = CloudSavesEngine.sync(steamRoot: steamRoot, syncRoot: sync, apps: [999])
        XCTAssertEqual(report.apps, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            sync.appendingPathComponent("123/456/remote/save.dat").path))
    }

    func testUnmanagedMirrorsAreQuarantined() throws {
        let fm = FileManager.default
        let sync = root.appendingPathComponent("cloud", isDirectory: true)
        let kept = sync.appendingPathComponent("123/456/remote/keep.dat")
        let removed = sync.appendingPathComponent("123/789/remote/drop.dat")
        let oldAccount = sync.appendingPathComponent("999/111/remote/old.dat")
        for file in [kept, removed, oldAccount] {
            try fm.createDirectory(at: file.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        let gone = CloudSavesEngine.removeUnmanaged(syncRoot: sync, keeping: [456])
        XCTAssertEqual(Set(gone), ["123/789", "999/111"])
        XCTAssertTrue(fm.fileExists(atPath: kept.path))
        XCTAssertFalse(fm.fileExists(atPath: removed.path))
        XCTAssertFalse(fm.fileExists(atPath: oldAccount.path))
        XCTAssertFalse(fm.fileExists(atPath: sync.appendingPathComponent("999").path))

        let quarantine = sync.appendingPathComponent(".macsteam-removed", isDirectory: true)
        let backups = try fm.subpathsOfDirectory(atPath: quarantine.path)
        XCTAssertTrue(backups.contains { $0.hasSuffix("drop.dat") })
        XCTAssertTrue(backups.contains { $0.hasSuffix("old.dat") })
    }

    func testCrossOverGameSaveFolderIsMirrored() throws {
        let fm = FileManager.default
        let local = steamRoot.appendingPathComponent(
            "userdata/123/456/ac/GameInstall/saves/settings.json")
        try fm.createDirectory(at: local.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("crossover-save".utf8).write(to: local)

        let sync = root.appendingPathComponent("cloud", isDirectory: true)
        let report = CloudSavesEngine.sync(steamRoot: steamRoot, syncRoot: sync, apps: [456])
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.copiedToCloud, 1)
        let mirrored = sync.appendingPathComponent(
            "123/456/ac/GameInstall/saves/settings.json")
        XCTAssertEqual(try Data(contentsOf: mirrored), Data("crossover-save".utf8))
    }

    // MARK: - Helpers

    private var steamRoot: URL {
        root.appendingPathComponent("steam", isDirectory: true)
    }

    private func localFile(_ name: String, contents: Data) throws -> URL {
        let url = steamRoot.appendingPathComponent("userdata/123/456/remote/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    private func cloudFile(_ name: String, _ sync: URL) -> URL {
        sync.appendingPathComponent("123/456/remote/\(name)")
    }
}
