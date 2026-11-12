import XCTest
import Foundation
@testable import MacsteamApp

private final class HubcapMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class HubcapRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ path: String) { lock.withLock { values.append(path) } }
    var paths: [String] { lock.withLock { values } }
}

@MainActor
final class HubcapStoreTests: XCTestCase {
    private var savedProvider = LuaProvider.current

    override func setUp() {
        super.setUp()
        savedProvider = LuaProvider.current
        LuaProvider.current = .hubcap
    }

    override func tearDown() {
        LuaProvider.current = savedProvider
        super.tearDown()
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hubcap-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func zip(_ root: URL, name: String = "123_456.manifest", bytes: Data? = nil) throws -> Data {
        let source = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent(name)
        try (bytes ?? Data([0xd0, 0x17, 0xf6, 0x71, 0x01, 0x00])).write(to: file)
        let archive = source.appendingPathComponent("archive.zip")
        let result = Subprocess.run("/usr/bin/zip", ["-j", archive.path, file.path])
        XCTAssertEqual(result.code, 0)
        return try Data(contentsOf: archive)
    }

    private func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> HubcapClient {
        HubcapMockProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubcapMockProtocol.self]
        return HubcapClient(session: URLSession(configuration: configuration))
    }

    func testCEFMarkerIsBesideTheUnbundledClient() throws {
        let root = try scratch()
        let client = root.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS")
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        try HubcapStoreBridge.enableCEFDebugging(in: client)
        let marker = client.appendingPathComponent(".cef-enable-remote-debugging")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(marker.lastPathComponent).path))
        try HubcapStoreBridge.enableCEFDebugging(in: client)
        XCTAssertEqual(try Data(contentsOf: marker).count, 0)
        let absent = root.appendingPathComponent("uninstalled-client")
        try HubcapStoreBridge.enableCEFDebugging(in: absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testInstalledStateComesFromAppManifestsInEveryLibrary() throws {
        let root = try scratch()
        let steam = root.appendingPathComponent("Steam")
        let other = root.appendingPathComponent("Games")
        for dir in [steam, other] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        }
        try "\"libraryfolders\" { \"1\" { \"path\" \"\(other.path)\" } }".write(
            to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)
        func manifest(_ library: URL, _ id: Int, flags: Int) throws {
            try "\"AppState\" { \"appid\" \"\(id)\" \"StateFlags\" \"\(flags)\" }".write(
                to: library.appendingPathComponent("steamapps/appmanifest_\(id).acf"), atomically: true, encoding: .utf8)
        }
        try manifest(steam, 620, flags: 4)        // fully installed
        try manifest(other, 400, flags: 4)        // installed on another library
        try manifest(steam, 730, flags: 1026)     // downloading / update required, not installed
        XCTAssertTrue(SteamInstallState.isFullyInstalled(appID: 620, steamRoot: steam))
        XCTAssertTrue(SteamInstallState.isFullyInstalled(appID: 400, steamRoot: steam))
        XCTAssertFalse(SteamInstallState.isFullyInstalled(appID: 730, steamRoot: steam))
        XCTAssertFalse(SteamInstallState.isFullyInstalled(appID: 999, steamRoot: steam))
        XCTAssertFalse(SteamInstallState.isFullyInstalled(appID: 0, steamRoot: steam))
    }

    @MainActor
    func testStatusReportsInstalledSoTheStoreCardCanHide() throws {
        let root = try scratch()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try "\"AppState\" { \"StateFlags\" \"4\" }".write(
            to: root.appendingPathComponent("steamapps/appmanifest_620.acf"), atomically: true, encoding: .utf8)
        let installer = HubcapStoreInstaller(client: client { _ in (200, Data()) })
        XCTAssertEqual(installer.status(appID: 620, steamRoot: root)["installed"] as? Bool, true)
        XCTAssertEqual(installer.status(appID: 621, steamRoot: root)["installed"] as? Bool, false)
    }

    func testStoreURLsAreScopedToSteamAppPages() {
        XCTAssertEqual(HubcapStoreBridge.storeAppID("https://store.steampowered.com/app/620/Portal_2/"), 620)
        for value in ["http://store.steampowered.com/app/620/", "https://store.steampowered.com.evil/app/620/",
                      "https://store.steampowered.com/sub/620/", "https://store.steampowered.com/app/0/",
                      "https://store.steampowered.com/app/2147483648/", "https://store.steampowered.com:444/app/620/"] {
            XCTAssertNil(HubcapStoreBridge.storeAppID(value), value)
        }
    }

    func testArchiveContainsActualRequestedDepotManifest() throws {
        let archive = try zip(scratch())
        let output = try HubcapManifestArchive.unpack(archive,
            references: [LuaManifestRef(depotID: 123, manifestGID: "456")])
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("123_456.manifest").path))
    }

    func testMissingOrInvalidManifestFailsBeforeConfigChange() throws {
        let root = try scratch()
        let archive = try zip(root)
        XCTAssertThrowsError(try HubcapManifestArchive.unpack(archive,
            references: [LuaManifestRef(depotID: 123, manifestGID: "999")]))
        let invalid = try zip(root, bytes: Data("<html>not a depot manifest</html>".utf8))
        XCTAssertThrowsError(try HubcapManifestArchive.unpack(invalid, references: []))
    }

    func testInstallCommitsFilesAndConfigBeforeActivationAndReusesDownloads() async throws {
        let root = try scratch()
        let archive = try zip(root)
        let lua = "addappid(42)\naddappid(123, 1, \"\(String(repeating: "a", count: 64))\")\nsetManifestid(123, \"456\")"
        let log = HubcapRequestLog()
        let api = client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer smm_" + String(repeating: "0", count: 96))
            log.append(request.url!.path)
            return (200, request.url!.path.contains("/lua/") ? Data(lua.utf8) : archive)
        }
        let store = ConfigStore(configFile: root.appendingPathComponent("config.yaml"), backupDir: root.appendingPathComponent("backups"))
        let depot = root.appendingPathComponent("depotcache")
        var activations = 0
        let installer = HubcapStoreInstaller(client: api, store: store,
            luaDirectory: root.appendingPathComponent("lua"), depotCache: depot, apiKey: { "smm_" + String(repeating: "0", count: 96) }, activate: { appID in
                XCTAssertEqual(appID, 42)
                XCTAssertTrue(store.config.apps.contains(42))
                XCTAssertTrue(FileManager.default.fileExists(atPath: depot.appendingPathComponent("123_456.manifest").path))
                activations += 1
                if activations == 1 { throw HubcapStoreError(message: "Simulated delayed Steam refresh") }
            })
        do { try await installer.install(appID: 42); XCTFail("Expected activation failure") } catch {}
        XCTAssertEqual(log.paths.count, 2)
        try await installer.install(appID: 42)
        XCTAssertEqual(log.paths.count, 2, "Retry must not consume additional Hubcap downloads")
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(Set(log.paths), ["/api/v1/lua/42", "/api/v1/manifest/42"])
    }

    func testWrongAppLuaNeverUpdatesConfiguration() async throws {
        let root = try scratch()
        let archive = try zip(root)
        let api = client { request in
            (200, request.url!.path.contains("/lua/") ? Data("addappid(99)".utf8) : archive)
        }
        let store = ConfigStore(configFile: root.appendingPathComponent("config.yaml"), backupDir: root.appendingPathComponent("backups"))
        let installer = HubcapStoreInstaller(client: api, store: store, luaDirectory: root.appendingPathComponent("lua"),
            depotCache: root.appendingPathComponent("depotcache"), apiKey: { "smm_" + String(repeating: "0", count: 96) }, activate: { _ in XCTFail("Must not activate") })
        do { try await installer.install(appID: 42); XCTFail("Must reject mismatched Lua") }
        catch { XCTAssertTrue(error.localizedDescription.contains("different game")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.yaml").path))
    }

    func testFailedDownloadLeavesExistingConfigurationUntouched() async throws {
        let root = try scratch()
        let config = root.appendingPathComponent("config.yaml")
        let original = "Apps:\n  - 100\nPackageIds:\n  - 20200\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let api = client { _ in (429, Data()) }
        let store = ConfigStore(configFile: config, backupDir: root.appendingPathComponent("backups"))
        let installer = HubcapStoreInstaller(client: api, store: store, luaDirectory: root.appendingPathComponent("lua"),
            depotCache: root.appendingPathComponent("depotcache"), apiKey: { "smm_" + String(repeating: "0", count: 96) }, activate: { _ in XCTFail("Must not activate") })
        do { try await installer.install(appID: 42); XCTFail("Must reject rate limiting") }
        catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("limit")) }
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }
}
