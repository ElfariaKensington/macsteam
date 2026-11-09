import XCTest
@testable import MacsteamApp

final class LuaToolsFixesTests: XCTestCase {
    @MainActor
    func testFixDetailSheetFittingWidthIsBounded() {
        let game = LuaToolsFixGame(appID: "470220", name: "UNO", headerImage: nil,
                                   fixCount: 1, tags: [])
        let fix = LuaToolsFix(id: "x", title: "x", description: "description",
                              tags: [], hasManifest: true, hasFix: true,
                              manifestFilename: nil, fixFilename: nil,
                              createdAt: nil)
        let detail = LuaToolsFixDetail(appID: "470220", name: "UNO",
                                       headerImage: nil, fixes: [fix])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsteam-sheet-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(configFile: root.appendingPathComponent("config.yaml"),
                                backupDir: root.appendingPathComponent("backups"))
        let vc = LuaToolsFixDetailViewController(game: game, detail: detail,
                                                  installDir: nil, store: store,
                                                  onConfigChanged: {})
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(vc.view.fittingSize.width, 900)
    }

    func testListingsDecode() throws {
        let json = #"""
        {
          "games": [
            {
              "appid": "470220",
              "name": "UNO",
              "header_image": "https://shared.akamai.steamstatic.com/uno.jpg",
              "fixCount": 3,
              "tags": [
                {"id": "tag-1", "name": "Generic", "slug": "generic", "color": "#ec4899"}
              ]
            }
          ],
          "tags": [
            {"id": "tag-1", "name": "Generic", "slug": "generic", "color": "#ec4899"}
          ]
        }
        """#
        let listing = try JSONDecoder().decode(LuaToolsFixListings.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(listing.games.count, 1)
        XCTAssertEqual(listing.games[0].appID, "470220")
        XCTAssertEqual(listing.games[0].numericAppID, 470220)
        XCTAssertEqual(listing.games[0].fixCount, 3)
        XCTAssertEqual(listing.games[0].tags.first?.name, "Generic")
        XCTAssertEqual(listing.tags.count, 1)
    }

    func testFixDetailDecode() throws {
        let json = #"""
        {
          "appid": "470220",
          "name": "UNO",
          "header_image": "https://shared.akamai.steamstatic.com/uno.jpg",
          "fixes": [
            {
              "id": "fix-1",
              "title": "470220",
              "description": "Apply / Extract and play!",
              "tags": [{"id": "tag-1", "name": "Generic", "slug": "generic", "color": "#ec4899"}],
              "hasManifest": true,
              "hasFix": true,
              "manifestFilename": "470220_470220.lua",
              "fixFilename": "470220.zip",
              "createdAt": "2026-08-19T08:00:05.036668+00:00"
            }
          ]
        }
        """#
        let detail = try JSONDecoder().decode(LuaToolsFixDetail.self,
                                              from: Data(json.utf8))
        XCTAssertEqual(detail.fixes.count, 1)
        let fix = detail.fixes[0]
        XCTAssertEqual(fix.title, "470220")
        XCTAssertEqual(fix.availability, "Manifest + fix available")
        XCTAssertEqual(fix.dateLabel, "19 Aug 2026")
        XCTAssertEqual(fix.manifestFilename, "470220_470220.lua")
    }

    func testWebURLContainsAppID() {
        XCTAssertEqual(LuaToolsFixesClient.webURL(appID: "470220").absoluteString,
                       "https://lua.tools/fixes?appid=470220")
    }

    @MainActor
    func testManifestInstall() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("macsteam-fixtest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let key = String(repeating: "a", count: 64)
        let lua = """
        -- Fixture Game
        addappid(470220, 1, "\(key)")
        setManifestid(470220, "123456789", 0)
        """
        let manifest = Data("manifest-fixture".utf8)
        let luaURL = root.appendingPathComponent("470220.lua")
        let manifestURL = root.appendingPathComponent("470220_123456789.manifest")
        try lua.write(to: luaURL, atomically: true, encoding: .utf8)
        try manifest.write(to: manifestURL)

        let zipURL = root.appendingPathComponent("fix.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-j", zipURL.path, luaURL.path, manifestURL.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let store = ConfigStore(configFile: root.appendingPathComponent("config.yaml"),
                                backupDir: root.appendingPathComponent("backups"))
        let luaDir = root.appendingPathComponent("lua", isDirectory: true)
        let depotCache = root.appendingPathComponent("depotcache", isDirectory: true)
        let result = try LuaToolsManifestInstaller.installManifest(
            data: try Data(contentsOf: zipURL),
            appID: 470220,
            store: store,
            luaDirectory: luaDir,
            depotCache: depotCache)

        XCTAssertEqual(result.appID, 470220)
        XCTAssertTrue(store.config.apps.contains(470220))
        XCTAssertTrue(fm.fileExists(atPath: luaDir.appendingPathComponent("470220.lua").path))
        XCTAssertTrue(fm.fileExists(
            atPath: depotCache.appendingPathComponent("470220_123456789.manifest").path))
        XCTAssertEqual(result.manifestCount, 1)
    }

    func testDiscordLoopbackCallback() async throws {
        let port: UInt16 = 53891
        let server = try LuaToolsLoopbackServer(port: port)
        defer { server.stop() }
        let task = Task { try await server.waitForCode(timeout: 10) }
        _ = try? await URLSession.shared.data(
            from: URL(string: "http://localhost:\(port)/favicon.ico")!)
        _ = try? await URLSession.shared.data(
            from: URL(string: "http://localhost:\(port)/callback?code=discord-code")!)
        let code = try await task.value
        XCTAssertEqual(code, "discord-code")
    }
}
