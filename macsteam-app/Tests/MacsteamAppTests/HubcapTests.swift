import Darwin
import XCTest
@testable import MacsteamApp

final class HubcapTests: XCTestCase {
    func testAPIKeyFormat() {
        let good = "smm_" + String(repeating: "a", count: 96)
        XCTAssertTrue(HubcapCredentialStore.isValidFormat(good))
        XCTAssertFalse(HubcapCredentialStore.isValidFormat("smm_short"))
        XCTAssertFalse(HubcapCredentialStore.isValidFormat("smm_" + String(repeating: "g", count: 96)))
        XCTAssertFalse(HubcapCredentialStore.isValidFormat("SMM_" + String(repeating: "a", count: 96)))
    }

    func testUserStatsDecodesDailyLimit() throws {
        let json = #"{"username":"air_on_user","daily_usage":2,"daily_limit":25,"can_make_requests":true,"api_key_expires_at":"2026-11-15T12:24:02","role_daily_limit":25}"#
        let stats = try JSONDecoder().decode(HubcapUserStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.username, "air_on_user")
        XCTAssertEqual(stats.dailyUsage, 2)
        XCTAssertEqual(stats.dailyLimit, 25)
        XCTAssertEqual(stats.summary, "2 of 25 downloads used today")
    }

    func testLuaParserGroupsDepotsAndDLC() {
        let lua = """
        -- 100's Lua and Manifest Created by Hubcap Manifest
        -- Example Game
        -- MAIN APPLICATION
        addappid(100, 1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") -- Example Game
        addappid(101, 1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") -- Windows
        -- DLC (AppID: 200)
        addappid(200)
        addappid(201, 1, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc") -- DLC depot
        setManifestid(101, "1234567890123456789", 0)
        setManifestid(201, "9876543210987654321", 0)
        """
        let script = LuaManifestParser.parse(lua)
        XCTAssertEqual(script.mainAppID, 100)
        XCTAssertEqual(script.dlcAppIDs, [200])
        XCTAssertEqual(script.depotKeys.map(\.depotID), [100, 101, 201])
        XCTAssertEqual(script.depotOwner[201], 200)
        XCTAssertEqual(script.parentByApp[200], 100)
        XCTAssertEqual(script.manifests.count, 2)
        XCTAssertEqual(script.manifests[0].fileName, "101_1234567890123456789.manifest")
    }

    func testArchiveAcceptsFlatManifestZip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("123.lua", to: dir)
        try Data(repeating: 0x41, count: 32).write(to: dir.appendingPathComponent("456_789.manifest"))
        let zip = try makeZip(dir)
        defer { try? FileManager.default.removeItem(at: zip) }
        let data = try Data(contentsOf: zip)
        let refs = [LuaManifestRef(depotID: 456, manifestGID: "789")]
        let contents = try HubcapManifestArchive.unpack(data, references: refs, expectedAppID: 123)
        defer { HubcapManifestArchive.cleanup(contents) }

        XCTAssertEqual(contents.luaText, luaFixture)
        let manifest = contents.manifestFiles.first {
            $0.lastPathComponent == refs[0].fileName
        }
        XCTAssertNotNil(manifest)
        XCTAssertEqual(try Data(contentsOf: manifest!).count, 32)
    }

    func testArchiveRejectsMissingManifest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("123.lua", to: dir)
        let zip = try makeZip(dir)
        defer { try? FileManager.default.removeItem(at: zip) }
        let data = try Data(contentsOf: zip)
        let refs = [LuaManifestRef(depotID: 999, manifestGID: "1")]
        XCTAssertThrowsError(try HubcapManifestArchive.unpack(
            data, references: refs, expectedAppID: 123))
    }

    func testArchiveRejectsUnexpectedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("123.lua", to: dir)
        try write("notes.txt", to: dir)
        let zip = try makeZip(dir)
        defer { try? FileManager.default.removeItem(at: zip) }
        let data = try Data(contentsOf: zip)
        XCTAssertThrowsError(try HubcapManifestArchive.unpack(
            data, references: [], expectedAppID: 123))
    }

    func testArchiveRejectsWrongLuaApp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("123.lua", to: dir)
        try Data(repeating: 0x41, count: 8).write(to: dir.appendingPathComponent("456_789.manifest"))
        let zip = try makeZip(dir)
        defer { try? FileManager.default.removeItem(at: zip) }
        let data = try Data(contentsOf: zip)
        XCTAssertThrowsError(try HubcapManifestArchive.unpack(
            data, references: [LuaManifestRef(depotID: 456, manifestGID: "789")],
            expectedAppID: 124))
    }

    func testUnknownTopLevelSettingsSurviveRoundTrip() {
        let parsed = MacsteamConfig.parse("""
        HideWhatsNew: yes
        HideCloudErrors: yes
        Apps:
          - 123  # Test
        """)
        XCTAssertTrue(parsed.hideWhatsNew)
        XCTAssertEqual(parsed.extraTopLevelLines, ["HideCloudErrors: yes"])
        let serialized = parsed.serialize()
        XCTAssertTrue(serialized.contains("HideCloudErrors: yes"))
        XCTAssertTrue(serialized.contains("HideWhatsNew: yes"))
        XCTAssertTrue(serialized.contains("  - 123  # Test"))
    }

    func testConfigMergeAddsDLCAndDepotOwner() {
        var cfg = MacsteamConfig()
        let plan = ImportPlan(
            sourceZip: URL(fileURLWithPath: "x.zip"),
            extractDir: FileManager.default.temporaryDirectory,
            mainAppID: 100,
            dlcAppIDs: [200],
            depotKeys: [(100, String(repeating: "a", count: 64)),
                        (201, String(repeating: "b", count: 64))],
            depotOwner: [100: 100, 201: 200],
            appNames: [100: "Example", 200: "DLC"],
            appParents: [200: 100],
            manifestFiles: [],
            luaTitle: "Example")
        _ = ZipImporter.merge(plan, into: &cfg)
        XCTAssertTrue(cfg.apps.contains(100))
        XCTAssertTrue(cfg.apps.contains(200))
        XCTAssertEqual(cfg.appParents[200], 100)
        XCTAssertEqual(cfg.depotKeyGroups.first(where: { $0.appID == 200 })?.depots.first?.depotID, 201)
        XCTAssertTrue(cfg.packageIds.contains(Paths.defaultInjectionPackage))
    }

    @MainActor
    func testInstallerDownloadsMergesAndCopiesManifests() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveDir = root.appendingPathComponent("api/v1/manifest", isDirectory: true)
        let luaDir = root.appendingPathComponent("api/v1/lua", isDirectory: true)
        let statusDir = root.appendingPathComponent("api/v1/status", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: luaDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)

        let lua = """
        -- 123's Lua and Manifest Created by Hubcap Manifest
        -- Fixture Game
        addappid(123, 1, "\(String(repeating: "a", count: 64))") -- Fixture Game
        addappid(456, 1, "\(String(repeating: "b", count: 64))") -- Fixture depot
        setManifestid(456, "789", 0)
        """
        try lua.write(to: luaDir.appendingPathComponent("123"), atomically: true, encoding: .utf8)
        try #"{"app_id":"999","game_name":"Status Game","status":"available","manifest_file_exists":true}"#
            .write(to: statusDir.appendingPathComponent("999"), atomically: true, encoding: .utf8)

        let fixtureDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: fixtureDir) }
        try lua.write(to: fixtureDir.appendingPathComponent("123.lua"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x42, count: 64)
            .write(to: fixtureDir.appendingPathComponent("456_789.manifest"))
        let zip = try makeZip(fixtureDir)
        defer { try? FileManager.default.removeItem(at: zip) }
        try FileManager.default.copyItem(at: zip, to: archiveDir.appendingPathComponent("123"))

        let server = try TestHTTPServer(root: root)
        defer { server.stop() }

        let configURL = root.appendingPathComponent("config.yaml")
        let store = ConfigStore(configFile: configURL,
                                backupDir: root.appendingPathComponent("backups"))
        store.load()
        let installer = HubcapStoreInstaller(
            client: HubcapClient(baseURL: server.baseURL),
            store: store,
            luaDirectory: root.appendingPathComponent("lua"),
            depotCache: root.appendingPathComponent("depotcache"),
            apiKey: { "smm_" + String(repeating: "a", count: 96) },
            luaToolsSources: { _ in [] },
            activate: { true })

        let status = await installer.status(appID: 999)
        if case .available(let name) = status {
            XCTAssertEqual(name, "Status Game")
        } else {
            XCTFail("expected available status, got \(status)")
        }

        let outcome = try await installer.install(appID: 123)
        XCTAssertTrue(outcome.activated)
        XCTAssertTrue(store.config.apps.contains(123))
        XCTAssertTrue(store.config.depotKeyGroups.contains {
            $0.appID == 123 && $0.depots.contains { $0.depotID == 456 }
        })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("depotcache/456_789.manifest").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("lua/123.lua").path))
        XCTAssertTrue(store.config.apps.contains(123))
        let ready = await installer.status(appID: 123)
        if case .ready = ready {
            // expected
        } else {
            XCTFail("expected ready status, got \(ready)")
        }
    }

    @MainActor
    func testLuaToolsIsPrimaryStoreSource() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(configFile: root.appendingPathComponent("config.yaml"),
                                backupDir: root.appendingPathComponent("backups"))
        let installer = HubcapStoreInstaller(
            store: store,
            luaDirectory: root.appendingPathComponent("lua"),
            depotCache: root.appendingPathComponent("depotcache"),
            apiKey: { nil },
            luaToolsSignedIn: { true },
            luaToolsSources: { _ in ["Luie"] },
            activate: { true })
        let status = await installer.status(appID: 123)
        if case .available = status {
            // expected: no Hubcap key needed when LuaTools has a source
        } else {
            XCTFail("expected LuaTools available status, got \(status)")
        }
    }

    // MARK: - Fixtures

    private let luaFixture = """
    -- 123's Lua and Manifest Created by Hubcap Manifest
    -- Fixture
    addappid(123)
    setManifestid(456, "789", 0)
    """

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsteam-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, to dir: URL) throws {
        try Data(luaFixture.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func makeZip(_ dir: URL) throws -> URL {
        let zip = dir.deletingLastPathComponent()
            .appendingPathComponent("\(dir.lastPathComponent).zip")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let paths = names.map { dir.appendingPathComponent($0).path }
        let result = Subprocess.run("/usr/bin/zip", ["-q", "-j", zip.path] + paths)
        XCTAssertEqual(result.code, 0, result.stderr)
        return zip
    }
}

final class TestHTTPServer {
    let baseURL: URL
    private let process: Process

    init(root: URL) throws {
        var chosen: (Process, URL)?
        for _ in 0..<8 {
            let port = Int.random(in: 20_000...40_000)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-m", "http.server", String(port),
                                 "--bind", "127.0.0.1", "--directory", root.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            if Self.waitForPort(port) {
                chosen = (process, URL(string: "http://127.0.0.1:\(port)")!)
                break
            }
            process.terminate()
            process.waitUntilExit()
        }
        guard let chosen else {
            throw NSError(domain: "TestHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start test HTTP server"])
        }
        self.process = chosen.0
        self.baseURL = chosen.1
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }

    private static func waitForPort(_ port: Int) -> Bool {
        for _ in 0..<30 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                close(fd)
                if ok { return true }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
