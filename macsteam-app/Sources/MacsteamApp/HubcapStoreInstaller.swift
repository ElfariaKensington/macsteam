// Turns a Hubcap Lua + manifest archive into a configured macSteam game.
import Foundation

struct HubcapInstallOutcome: Sendable {
    let activated: Bool
    let luaTitle: String?
}

private func defaultLuaToolsSignedIn() async -> Bool {
    await LuaToolsAuth.shared.isSignedIn()
}

private func defaultLuaToolsSources(_ appID: Int) async -> [String] {
    guard await LuaToolsAuth.shared.isSignedIn() else { return [] }
    return (try? await LuaToolsGamesClient.shared.sources(appID: appID)) ?? []
}

enum StoreAddError: LocalizedError {
    case luaToolsSignInRequired

    var errorDescription: String? {
        "Sign in with Discord in macSteam Config → Settings to add games."
    }
}

@MainActor
final class HubcapStoreInstaller {
    enum StoreStatus: Sendable {
        case ready
        case available(gameName: String?)
        case unavailable(String)
    }

    private let client: HubcapClient
    private let store: ConfigStore
    private let games = LuaToolsGamesClient.shared
    private let luaToolsSignedIn: () async -> Bool
    private let luaToolsSources: (Int) async -> [String]
    private let luaDirectory: URL
    private let depotCache: URL
    private let apiKey: () -> String?
    private let activate: () async -> Bool

    init(client: HubcapClient = .shared,
         store: ConfigStore,
         luaDirectory: URL = Paths.luaDir,
         depotCache: URL = Paths.depotCache,
         apiKey: @escaping () -> String? = { HubcapCredentialStore.apiKey },
         luaToolsSignedIn: @escaping () async -> Bool = defaultLuaToolsSignedIn,
         luaToolsSources: @escaping (Int) async -> [String] = defaultLuaToolsSources,
         activate: @escaping () async -> Bool = { await HubcapActivation.requestRefresh() }) {
        self.client = client
        self.store = store
        self.luaDirectory = luaDirectory
        self.depotCache = depotCache
        self.apiKey = apiKey
        self.luaToolsSignedIn = luaToolsSignedIn
        self.luaToolsSources = luaToolsSources
        self.activate = activate
    }

    func isConfigured(appID: Int) -> Bool {
        // The store bridge runs in a helper process, so another process may have added
        // or removed games since this ConfigStore was loaded.
        store.reloadFromDisk()
        return store.config.apps.contains(appID)
    }

    func status(appID: Int) async -> StoreStatus {
        if isConfigured(appID: appID) { return .ready }

        // LuaTools is the primary source whenever a Discord session exists.
        let signedIn = await luaToolsSignedIn()
        if signedIn {
            let sources = await luaToolsSources(appID)
            if sources.first != nil {
                return .available(gameName: store.config.appNames[appID])
            }
        }

        guard let key = apiKey(), HubcapCredentialStore.isValidFormat(key) else {
            if signedIn {
                return .unavailable("LuaTools has no available source for this game.")
            }
            return .unavailable(
                "Sign in with Discord in macSteam Config → Settings, or add a Hubcap API key.")
        }
        do {
            guard let status = try await client.manifestStatus(appID: appID, apiKey: key) else {
                return .unavailable("Hubcap doesn't have a Lua manifest for this game.")
            }
            guard status.isAvailable else {
                return .unavailable("Hubcap's manifest for this game isn't available yet.")
            }
            return .available(gameName: status.gameName)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func install(appID: Int) async throws -> HubcapInstallOutcome {
        guard appID > 0, appID <= 2_147_483_647 else {
            throw HubcapClientError.invalidResponse
        }
        if isConfigured(appID: appID) {
            let activated = await activate()
            return HubcapInstallOutcome(activated: activated, luaTitle: nil)
        }

        let key = apiKey().flatMap {
            HubcapCredentialStore.isValidFormat($0) ? $0 : nil
        }

        // LuaTools first, exactly like the Store tab.
        if await luaToolsSignedIn() {
            do {
                guard let source = await luaToolsSources(appID).first else {
                    throw LuaToolsGamesError.noSources
                }
                let name = store.config.appNames[appID] ?? "App \(appID)"
                let data = try await games.downloadManifest(
                    appID: appID, source: source, gameName: name)
                let result = try LuaToolsManifestInstaller.installManifest(
                    data: data, appID: appID, store: store,
                    luaDirectory: luaDirectory, depotCache: depotCache)
                let activated = await activate()
                HubcapLog.write("Store add used LuaTools source \(source) for app \(appID).")
                return HubcapInstallOutcome(activated: activated, luaTitle: result.title)
            } catch {
                HubcapLog.write("LuaTools store add failed for app \(appID): "
                                + "\(error.localizedDescription)")
                guard key != nil else { throw error }
            }
        }

        guard let key else {
            throw StoreAddError.luaToolsSignInRequired
        }

        // Fetch the small Lua first so an unsupported/DLC page fails before the big ZIP.
        async let luaTextAsync = client.downloadLuaText(appID: appID, apiKey: key)
        async let archiveAsync = client.downloadManifestArchive(appID: appID, apiKey: key)
        let (downloadedLua, archiveData) = try await (luaTextAsync, archiveAsync)

        let script = LuaManifestParser.parse(downloadedLua)
        guard let mainAppID = script.mainAppID, mainAppID == appID else {
            throw HubcapClientError.http(
                422, "Hubcap returned Lua for a different game. Nothing was added.")
        }
        guard (1...512).contains(script.depotKeys.count) else {
            throw HubcapClientError.invalidLuaResponse
        }

        let contents = try HubcapManifestArchive.unpack(
            archiveData, references: script.manifests, expectedAppID: appID)
        defer { HubcapManifestArchive.cleanup(contents) }

        // The archive Lua is the canonical one: the /lua endpoint strips setManifestid
        // lines, while the copy inside the ZIP matches the manifest files beside it.
        let archiveScript = LuaManifestParser.parse(contents.luaText)
        guard archiveScript.mainAppID == appID,
              (1...512).contains(archiveScript.depotKeys.count) else {
            throw HubcapClientError.http(
                422, "Hubcap returned Lua for a different game. Nothing was added.")
        }
        for ref in archiveScript.manifests where !contents.manifestFiles.contains(where: {
            $0.lastPathComponent == ref.fileName
        }) {
            throw HubcapArchiveError.missingManifest(ref.fileName)
        }

        let plan = ImportPlan(
            sourceZip: URL(fileURLWithPath: "hubcap-\(appID).zip"),
            extractDir: contents.directory,
            mainAppID: appID,
            dlcAppIDs: archiveScript.dlcAppIDs,
            depotKeys: archiveScript.depotKeys,
            depotOwner: archiveScript.depotOwner,
            appNames: archiveScript.appNames,
            appParents: archiveScript.parentByApp,
            manifestFiles: contents.manifestFiles,
            luaTitle: title(from: contents.luaText))

        let manifestFiles = plan.manifestFiles
        _ = try ZipImporter.copyManifests(manifestFiles, to: depotCache)

        let luaURL = luaDirectory.appendingPathComponent("\(appID).lua")
        var wroteLua = false
        do {
            try Paths.ensureDir(luaDirectory)
            try contents.luaText.write(to: luaURL, atomically: true, encoding: .utf8)
            wroteLua = true

            try store.mutate { cfg in
                _ = ZipImporter.merge(plan, into: &cfg)
            }
        } catch {
            ZipImporter.removeCopiedManifests(manifestFiles, from: depotCache)
            if wroteLua { try? FileManager.default.removeItem(at: luaURL) }
            throw error
        }

        let activated = await activate()
        return HubcapInstallOutcome(activated: activated, luaTitle: plan.luaTitle)
    }

    private func title(from lua: String) -> String? {
        for line in lua.split(separator: "\n").prefix(8) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("--") else { continue }
            let body = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.contains("Lua and Manifest") ||
                body.hasPrefix("Created:") || body.hasPrefix("Website:") ||
                body.hasPrefix("Build") || body.hasPrefix("Total ") ||
                body.hasPrefix("MAIN ") || body.hasPrefix("DLCS ") ||
                body.uppercased() == body && body.contains("APP") {
                continue
            }
            return body
        }
        return nil
    }
}

// MARK: - Live activation handshake

enum HubcapActivation {
    static func requestRefresh(timeout: TimeInterval = 8) async -> Bool {
        let token = UUID().uuidString
        do {
            try Paths.ensureDir(Paths.configDir)
            try (token + "\n").write(to: Paths.hubcapRefreshRequest,
                                     atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if let text = try? String(contentsOf: Paths.hubcapRefreshAck, encoding: .utf8) {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if let first = lines.first.map(String.init),
                   first.trimmingCharacters(in: .whitespacesAndNewlines) == token {
                    let status = lines.count > 1
                        ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    return status != "error"
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
