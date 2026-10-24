// Unlock zip/lua importer
import Foundation

struct ImportPlan {
    let planID = UUID()
    var sourceZip: URL
    // Extraction temp dir, owned by the plan: deleted at apply or when the plan leaves
    // the review. Nothing else may assume it outlives the plan.
    var extractDir: URL
    var mainAppID: Int?
    var dlcAppIDs: [Int] = []
    var depotKeys: [(depotID: Int, key: String)]
    var depotOwner: [Int: Int] = [:]
    // App id to lua display name, persisted so the pane can name apps the store can't.
    var appNames: [Int: String] = [:]
    // DLC app id to parent (the lua's main app), persisted so nesting holds offline.
    var appParents: [Int: Int] = [:]
    var manifestFiles: [URL]        // in temp dir, ready to copy
    var luaTitle: String?
}

enum ImportError: LocalizedError {
    case unzipFailed(String)
    case noLua
    case luaReadFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let m): return "Failed to unzip: \(m)"
        case .noLua:              return "No .lua script found in the zip."
        case .luaReadFailed(let name, let e): return "Couldn't read \(name): \(e.localizedDescription)"
        }
    }
}

enum ZipImporter {

    // Prefix for extraction dirs, so a sweep can spot ones orphaned by a crash.
    private static let extractPrefix = "macsteam-import-"

    static func buildPlans(from zip: URL) throws -> [ImportPlan] {
        let scoped = zip.startAccessingSecurityScopedResource()
        defer { if scoped { zip.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(extractPrefix)\(UUID().uuidString)", isDirectory: true)
        try Paths.ensureDir(tmp)
        try unzip(zip, into: tmp)

        let plans = try plansFromDirectory(tmp, source: zip)
        if plans.isEmpty {
            cleanup(tmp)
            throw ImportError.noLua
        }
        return plans
    }

    static func buildPlans(fromFolder folder: URL) throws -> [ImportPlan] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(extractPrefix)\(UUID().uuidString)", isDirectory: true)
        try Paths.ensureDir(tmp)

        // Copy folder contents into a temp dir so cleanup stays uniform.
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for item in items {
            try fm.copyItem(at: item, to: tmp.appendingPathComponent(item.lastPathComponent))
        }

        let plans = try plansFromDirectory(tmp, source: folder)
        if plans.isEmpty {
            cleanup(tmp)
            throw ImportError.noLua
        }
        return plans
    }

    static func buildPlan(fromLuaText luaText: String, source: URL) throws -> ImportPlan {
        guard LuaManifestParser.containsAddApp(luaText) else {
            throw ImportError.noLua
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(extractPrefix)\(UUID().uuidString)", isDirectory: true)
        return makePlan(source: source, extractDir: tmp, luaText: luaText, manifests: [])
    }

    static func buildPlan(fromLua lua: URL) throws -> ImportPlan {
        let luaText: String
        do { luaText = try String(contentsOf: lua, encoding: .utf8) }
        catch { throw ImportError.luaReadFailed(lua.lastPathComponent, error) }
        return try buildPlan(fromLuaText: luaText, source: lua)
    }

    // Scan a directory for game plans. Handles both flat (lua + manifests at root)
    // and multi-gen (subdirectories each containing a lua + manifests).
    private static func plansFromDirectory(_ dir: URL, source: URL) throws -> [ImportPlan] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])

        // Flat: lua at root level
        if let luaURL = contents.first(where: { $0.pathExtension.lowercased() == "lua" }) {
            let luaText: String
            do { luaText = try String(contentsOf: luaURL, encoding: .utf8) }
            catch { throw ImportError.luaReadFailed(luaURL.lastPathComponent, error) }
            let manifests = contents.filter { $0.pathExtension.lowercased() == "manifest" }
            return [makePlan(source: source, extractDir: dir, luaText: luaText, manifests: manifests)]
        }

        // Multi-gen: subdirectories each containing a lua
        var plans: [ImportPlan] = []
        let subdirs = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for subdir in subdirs {
            let subContents = try fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil)
            guard let luaURL = subContents.first(where: { $0.pathExtension.lowercased() == "lua" }) else { continue }
            let luaText: String
            do { luaText = try String(contentsOf: luaURL, encoding: .utf8) }
            catch { continue }
            let manifests = subContents.filter { $0.pathExtension.lowercased() == "manifest" }
            plans.append(makePlan(source: source, extractDir: dir, luaText: luaText, manifests: manifests))
        }
        return plans
    }

    private static func makePlan(source: URL, extractDir: URL,
                                 luaText: String, manifests: [URL]) -> ImportPlan {
        let script = LuaManifestParser.parse(luaText)
        return ImportPlan(
            sourceZip: source,
            extractDir: extractDir,
            mainAppID: script.mainAppID,
            dlcAppIDs: script.dlcAppIDs,
            depotKeys: script.depotKeys,
            depotOwner: script.depotOwner,
            appNames: script.appNames,
            appParents: script.parentByApp,
            manifestFiles: manifests,
            luaTitle: titleFromLua(luaText)
        )
    }

    // Best-effort: a failed remove is disk litter the next sweep catches.
    static func cleanup(_ extractDir: URL) {
        try? FileManager.default.removeItem(at: extractDir)
    }

    // Remove leftover extraction dirs. Only safe with no batch loaded: it can't tell a
    // stale dir from one a live plan references, so the caller must guarantee no live plans.
    static func sweepStaleExtractDirs() {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(extractPrefix) {
            try? fm.removeItem(at: url)
        }
    }

    @discardableResult
    static func copyManifests(_ files: [URL]) throws -> Int {
        try Paths.ensureDir(Paths.depotCache)
        var n = 0
        for src in files {
            let dst = Paths.depotCache.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            n += 1
        }
        return n
    }

    // Undo copyManifests when the config save fails after, so depotcache keeps no
    // unreferenced manifests. Best-effort.
    static func removeCopiedManifests(_ files: [URL]) {
        for src in files {
            let dst = Paths.depotCache.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
        }
    }

    // Merges into the config model only. Does not write to disk.
    @discardableResult
    static func merge(_ plan: ImportPlan, into cfg: inout MacsteamConfig) -> [String] {
        var changes: [String] = []
        guard let app = plan.mainAppID else { return ["No main app id; nothing merged."] }

        if cfg.addApp(app) { changes.append("Added app \(app) to Apps") }
        if cfg.addPackage(Paths.defaultInjectionPackage) {
            changes.append("Added package \(Paths.defaultInjectionPackage) to PackageIds")
        }
        // Ownership gates key off the flat Apps list (sx_config_has_app), so each DLC
        // appid must be in Apps to unlock.
        var dlcAdded = 0
        for dlc in plan.dlcAppIDs where cfg.addApp(dlc) { dlcAdded += 1 }
        if dlcAdded > 0 {
            changes.append("Added \(dlcAdded) DLC app(s) to Apps: "
                + plan.dlcAppIDs.map(String.init).joined(separator: ", "))
        }
        for id in cfg.apps {
            if let name = plan.appNames[id], cfg.appNames[id] != name {
                cfg.appNames[id] = name
            }
            if let parent = plan.appParents[id], cfg.appParents[id] != parent {
                cfg.appParents[id] = parent
            }
        }
        // File each depot under its owner's appid group (base under main, DLC under its
        // appid) so a DLC's depots drop with it. Runtime key lookup is group-agnostic
        // (sx_config_get_depot_key_any), so grouping never affects decryption. Unknown
        // depots fall back to the main app.
        var depotCount = 0
        for (depot, key) in plan.depotKeys {
            let owner = plan.depotOwner[depot] ?? app
            if cfg.upsertDepotKey(appID: owner, depotID: depot, key: key) {
                depotCount += 1
            }
        }
        if depotCount > 0 {
            changes.append("Added \(depotCount) depot key(s)")
        }
        if changes.isEmpty { changes.append("No config changes (already present).") }
        return changes
    }

    // MARK: - internals

    private static func unzip(_ zip: URL, into dir: URL) throws {
        let result = Subprocess.run("/usr/bin/unzip", ["-o", zip.path, "-d", dir.path])
        if result.code != 0 {
            throw ImportError.unzipFailed(result.stderr.isEmpty ? "status \(result.code)" : result.stderr)
        }
    }

    // Hubcap lua files put the game name on line 2 as a comment "-- <Name>".
    private static func titleFromLua(_ text: String) -> String? {
        for line in text.split(separator: "\n").prefix(6) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("--") else { continue }
            let body = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            // Skip the header/meta lines Hubcap emits before the title.
            if body.contains("Lua and Manifest") || body.hasPrefix("Created:") ||
               body.hasPrefix("Website:") || body.hasPrefix("Total ") ||
               body.hasPrefix("Shared ") || body.uppercased() == body && body.contains("APP") {
                continue
            }
            return body
        }
        return nil
    }
}
