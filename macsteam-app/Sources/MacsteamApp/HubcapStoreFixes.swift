// Game-fix actions for the Steam store page: list a game's LuaTools fixes, install
// the manifest or the game-file fix, and undo a fix. Runs inside the store bridge.
import AppKit
import Foundation

@MainActor
final class HubcapStoreFixes {
    private let store: ConfigStore
    private var working = false

    init(store: ConfigStore) {
        self.store = store
    }

    /// Fixes LuaTools offers for the game, plus what is already applied on disk.
    func list(appID: Int) async -> [String: Any] {
        store.load()
        let manifestInstalled = store.config.apps.contains(appID)
        let installDir = SteamLibrary.installDir(appID: appID)
        let applied = Set(installDir.map { SteamFixInstaller.appliedFixes(installDir: $0).map(\.fixID) } ?? [])
        do {
            let detail = try await LuaToolsFixesClient.shared.fixes(appID: String(appID))
            let fixes: [[String: Any]] = detail.fixes.map { fix in
                [
                    "id": fix.id,
                    "title": fix.title,
                    "description": fix.description ?? "",
                    "hasManifest": fix.hasManifest,
                    "hasFix": fix.hasFix,
                    "applied": applied.contains(fix.id),
                ]
            }
            return ["fixes": fixes, "gameInstalled": installDir != nil,
                    "manifestInstalled": manifestInstalled]
        } catch LuaToolsFixesError.noFixes {
            return ["fixes": [] as [[String: Any]], "gameInstalled": installDir != nil,
                    "manifestInstalled": manifestInstalled]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Runs one fix action and returns a message for the page.
    func perform(_ action: String, appID: Int, fixID: String) async -> [String: Any] {
        guard !working else { return ["error": "Another fix is in progress. Try again when it finishes."] }
        working = true
        defer { working = false }
        do {
            let message: String
            switch action {
            case "fix-manifest": message = try await installManifest(appID: appID, fixID: fixID)
            case "fix-install": message = try await installFix(appID: appID, fixID: fixID)
            case "fix-undo": message = try undo(appID: appID, fixID: fixID)
            default: return ["error": "Unknown fix action."]
            }
            var response = await list(appID: appID)
            response["message"] = message
            return response
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func ensureSignedIn() async throws {
        if !(await LuaToolsAuth.shared.isSignedIn()) {
            _ = try await LuaToolsAuth.shared.signIn()
        }
    }

    private func installManifest(appID: Int, fixID: String) async throws -> String {
        try await ensureSignedIn()
        let data = try await LuaToolsFixesClient.shared.downloadManifest(fixID: fixID)
        store.load()
        let result = try LuaToolsManifestInstaller.installManifest(
            data: data, appID: appID, store: store)
        _ = await HubcapActivation.requestRefresh()
        return "Installed \(result.title) · \(result.manifestCount) manifest"
            + (result.manifestCount == 1 ? "" : "s") + ". Restart Steam to finish."
    }

    private func installFix(appID: Int, fixID: String) async throws -> String {
        guard let installDir = SteamLibrary.installDir(appID: appID) else {
            throw SteamFixInstallError.noInstallDir
        }
        try await ensureSignedIn()
        let data = try await LuaToolsFixesClient.shared.downloadFix(fixID: fixID)
        let result = try await Task.detached {
            try SteamFixInstaller.apply(zipData: data, appID: appID, fixID: fixID,
                                        installDir: installDir)
        }.value
        return "Fix installed · \(result.modified) replaced · \(result.added) added"
    }

    private func undo(appID: Int, fixID: String) throws -> String {
        guard let installDir = SteamLibrary.installDir(appID: appID) else {
            throw SteamFixInstallError.noInstallDir
        }
        let result = try SteamFixInstaller.revert(installDir: installDir, fixID: fixID)
        return "Fix undone · \(result.restored) restored · \(result.removed) removed"
    }
}
