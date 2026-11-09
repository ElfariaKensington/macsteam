// Install the "manifest" slot of a LuaTools Denuvo fix: force-locked Lua plus its
// depot manifests, merged into macSteam's config/depot cache.
import Foundation

enum LuaToolsManifestInstallError: LocalizedError {
    case appMismatch(Int)
    case noLua
    case luaReadFailed

    var errorDescription: String? {
        switch self {
        case .appMismatch(let appID):
            return "The downloaded fix isn't for App \(appID). Nothing was installed."
        case .noLua:
            return "The downloaded fix contains no Lua file."
        case .luaReadFailed:
            return "Couldn't read the downloaded Lua file."
        }
    }
}

@MainActor
enum LuaToolsManifestInstaller {
    struct Result {
        let appID: Int
        let title: String
        let manifestCount: Int
        let changes: [String]
    }

    static func installManifest(data: Data,
                                appID: Int,
                                store: ConfigStore,
                                luaDirectory: URL = Paths.luaDir,
                                depotCache: URL = Paths.depotCache) throws -> Result {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("macsteam-luafix-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensureDir(work)
        defer { try? fm.removeItem(at: work) }

        let isZip = data.count >= 4
            && data[data.startIndex] == 0x50
            && data[data.startIndex + 1] == 0x4B
        let source = work.appendingPathComponent(isZip ? "fix.zip" : "\(appID).lua")
        try data.write(to: source, options: .atomic)

        let plans: [ImportPlan]
        if isZip {
            plans = try ZipImporter.buildPlans(from: source)
        } else {
            plans = [try ZipImporter.buildPlan(fromLua: source)]
        }
        guard let plan = plans.first(where: { $0.mainAppID == appID }) else {
            throw LuaToolsManifestInstallError.appMismatch(appID)
        }

        let luaText: String
        if isZip {
            guard let found = findLua(appID: appID, in: plan.extractDir) else {
                throw LuaToolsManifestInstallError.noLua
            }
            luaText = found
        } else {
            guard let text = try? String(contentsOf: source, encoding: .utf8) else {
                throw LuaToolsManifestInstallError.luaReadFailed
            }
            luaText = text
        }

        let manifestFiles = plan.manifestFiles
        let luaURL = luaDirectory.appendingPathComponent("\(appID).lua")
        let isDefaultInstall = luaDirectory.standardizedFileURL == Paths.luaDir.standardizedFileURL
            && depotCache.standardizedFileURL == Paths.depotCache.standardizedFileURL
        var wroteLua = false
        do {
            try Paths.ensureDir(luaDirectory)
            try luaText.write(to: luaURL, atomically: true, encoding: .utf8)
            wroteLua = true

            let copied = try ZipImporter.copyManifests(manifestFiles, to: depotCache)
            var changes: [String] = []
            try store.mutate { cfg in
                changes = ZipImporter.merge(plan, into: &cfg)
            }
            if isDefaultInstall {
                LuaToolsLog.write("Manifest installed: app=\(appID), "
                                  + "manifests=\(copied), lua=\(luaURL.lastPathComponent).")
            }
            return Result(
                appID: appID,
                title: plan.luaTitle ?? "App \(appID)",
                manifestCount: copied,
                changes: changes)
        } catch {
            if isDefaultInstall {
                LuaToolsLog.write("Manifest install failed for app \(appID): "
                                  + "\(error.localizedDescription)")
            }
            ZipImporter.removeCopiedManifests(manifestFiles, from: depotCache)
            if wroteLua { try? fm.removeItem(at: luaURL) }
            throw error
        }
    }

    private static func findLua(appID: Int, in directory: URL) -> String? {
        guard let en = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in en where url.pathExtension.lowercased() == "lua" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if LuaManifestParser.parse(text).mainAppID == appID {
                return text
            }
        }
        return nil
    }
}
