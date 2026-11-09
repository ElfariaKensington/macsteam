import Foundation
import Darwin
import CoreFoundation

struct HubcapStoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns the complete download -> validate -> persist -> live activation transaction.
@MainActor
final class HubcapStoreInstaller {
    private let client: HubcapClient
    private let store: ConfigStore
    private var installing = false
    private let luaDirectory: URL
    private let depotCache: URL
    private let apiKey: () -> String?
    private let activate: (Int) async throws -> Void

    init(client: HubcapClient = HubcapClient(), store: ConfigStore = ConfigStore(),
         luaDirectory: URL = Paths.configDir.appendingPathComponent("hubcap-lua"),
         depotCache: URL = Paths.depotCache,
         apiKey: @escaping () -> String? = { HubcapCredentialStore.apiKey },
         activate: @escaping (Int) async throws -> Void = { try await SteamLibraryActivation.refresh(appID: $0) }) {
        self.client = client
        self.store = store
        self.luaDirectory = luaDirectory
        self.depotCache = depotCache
        self.apiKey = apiKey
        self.activate = activate
    }

    func status(appID: Int) -> [String: Any] {
        store.load()
        let configured = store.config.apps.contains(appID)
        return ["configured": configured, "ready": configured && SteamLibraryActivation.isActive(appID)]
    }

    func install(appID: Int) async throws {
        guard !installing else {
            throw HubcapStoreError(message: "Another game is being added. Please try again when it finishes.")
        }
        installing = true
        defer { installing = false }
        store.load()
        // A refresh retry never consumes another Hubcap download.
        let receipt = luaDirectory.appendingPathComponent("\(appID).lua")
        if !store.config.apps.contains(appID) || !FileManager.default.fileExists(atPath: receipt.path) {
            switch LuaProvider.current {
            case .luaTools: try await installFromLuaTools(appID: appID, receipt: receipt)
            case .hubcap: try await installFromHubcap(appID: appID, receipt: receipt)
            }
        }
        try await activate(appID)
    }

    private func installFromLuaTools(appID: Int, receipt: URL) async throws {
        guard await LuaToolsAuth.shared.isSignedIn() else {
            throw HubcapStoreError(message: "Sign in with Discord in macSteam Config → Settings to add games.")
        }
        guard let source = try await LuaToolsGamesClient.shared.sources(appID: appID).first else {
            throw HubcapStoreError(message: "LuaTools has no available source for this game.")
        }
        let name = store.config.appNames[appID] ?? "App \(appID)"
        let data = try await LuaToolsGamesClient.shared.downloadManifest(
            appID: appID, source: source, gameName: name)
        _ = try LuaToolsManifestInstaller.installManifest(
            data: data, appID: appID, store: store,
            luaDirectory: luaDirectory, depotCache: depotCache)
        // Marker so a failed activation retry doesn't spend another LuaTools download.
        try Paths.ensureDir(receipt.deletingLastPathComponent())
        try Data().write(to: receipt, options: .atomic)
    }

    private func installFromHubcap(appID: Int, receipt: URL) async throws {
        guard let key = apiKey() else {
            throw HubcapStoreError(message: "Open Hubcap in macSteam Config and connect your API key first.")
        }
        async let lua = client.downloadLuaText(appID: appID, apiKey: key)
        async let archive = client.downloadManifestArchive(appID: appID, apiKey: key)
        let (text, zip) = try await (lua, archive)
        let plan = try ZipImporter.buildPlan(fromLuaText: text,
            source: URL(fileURLWithPath: "hubcap-\(appID).lua"))
        defer { ZipImporter.cleanup(plan.extractDir) }
        guard plan.mainAppID == appID else {
            throw HubcapStoreError(message: "Hubcap returned Lua for a different game. Nothing was added.")
        }
        // Only parse Lua data; never execute downloaded Lua.
        let script = LuaManifestParser.parse(text)
        guard script.entries.allSatisfy({ $0.id > 0 && $0.id <= Int32.max && ($0.key == nil || $0.key?.count == 64) }),
              script.manifests.allSatisfy({ $0.depotID > 0 && $0.depotID <= Int32.max && (UInt64($0.manifestGID) ?? 0) > 0 }) else {
            throw HubcapStoreError(message: "Hubcap returned invalid app IDs, depot keys, or manifest IDs.")
        }
        let manifests = try await Task.detached(priority: .userInitiated) {
            try HubcapManifestArchive.unpack(zip, references: script.manifests)
        }.value
        defer { try? FileManager.default.removeItem(at: manifests) }
        try Paths.ensureDir(depotCache)
        for file in try FileManager.default.contentsOfDirectory(at: manifests,
            includingPropertiesForKeys: nil) where file.pathExtension == "manifest" {
            let data = try Data(contentsOf: file)
            try data.write(to: depotCache.appendingPathComponent(file.lastPathComponent), options: .atomic)
        }
        try Paths.ensureDir(receipt.deletingLastPathComponent())
        // Config is the commit point. Files already validated and safely staged on disk.
        try store.mutate { _ = ZipImporter.merge(plan, into: &$0) }
        try text.write(to: receipt, atomically: true, encoding: .utf8)
    }
}

enum HubcapManifestArchive {
    static func unpack(_ data: Data, references: [LuaManifestRef]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macsteam-hubcap-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: root) } }
        let zip = root.appendingPathComponent("download.zip")
        try data.write(to: zip)
        let listing = Subprocess.run("/usr/bin/unzip", ["-l", zip.path])
        guard listing.code == 0 else { throw HubcapStoreError(message: "Hubcap's manifest ZIP is damaged.") }
        let line = try NSRegularExpression(pattern: #"(?m)^\s*(\d+)\s+\d{2,4}-\d{2}-\d{2,4}\s+\d{2}:\d{2}\s+(.+)$"#)
        let ns = listing.stdout as NSString
        let entries = line.matches(in: listing.stdout, range: NSRange(location: 0, length: ns.length))
        guard !entries.isEmpty, entries.count <= 4096 else {
            throw HubcapStoreError(message: "Hubcap's manifest ZIP has no readable directory.")
        }
        let output = root.appendingPathComponent("manifests")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let expected = Set(references.map { "\($0.depotID)_\($0.manifestGID).manifest" })
        var found = Set<String>()
        var total = 0
        for entry in entries {
            let size = Int(ns.substring(with: entry.range(at: 1))) ?? Int.max
            guard size <= 64 * 1024 * 1024, total <= 512 * 1024 * 1024 - size else {
                throw HubcapStoreError(message: "Hubcap's manifest ZIP exceeds the extraction limit.")
            }
            total += size
            let path = ns.substring(with: entry.range(at: 2))
            let name = (path as NSString).lastPathComponent
            guard name.range(of: #"^[1-9][0-9]*_[1-9][0-9]*\.manifest$"#,
                             options: .regularExpression) != nil else { continue }
            guard !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/").contains(".."), !found.contains(name) else {
                throw HubcapStoreError(message: "Hubcap's manifest ZIP contains an unsafe or duplicate filename.")
            }
            if !expected.isEmpty && !expected.contains(name) { continue }
            let destination = output.appendingPathComponent(name)
            fm.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", zip.path, path]
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); try handle.close() }
            catch { try? handle.close(); throw error }
            let bytes = try Data(contentsOf: destination, options: .mappedIfSafe)
            guard process.terminationStatus == 0, bytes.count == size,
                  bytes.starts(with: [0xd0, 0x17, 0xf6, 0x71]) else {
                throw HubcapStoreError(message: "Hubcap returned an invalid Steam depot manifest: \(name).")
            }
            found.insert(name)
        }
        guard !found.isEmpty, expected.isSubset(of: found) else {
            throw HubcapStoreError(message: "Hubcap's ZIP is missing manifests referenced by this game's Lua.")
        }
        try fm.removeItem(at: zip)
        // Caller owns the parent too, so return the root with flat manifest files.
        for file in try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
            try fm.moveItem(at: file, to: root.appendingPathComponent(file.lastPathComponent))
        }
        try fm.removeItem(at: output)
        success = true
        return root
    }
}

enum SteamLibraryActivation {
    static let notification = "com.macsteam.hubcap.refresh"
    static func isActive(_ appID: Int) -> Bool {
        let file = Paths.configDir.appendingPathComponent("hubcap-runtime.apps")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n")
        guard let first = lines.first, let pid = Int32(first), pid > 1, kill(pid, 0) == 0 else { return false }
        return lines.dropFirst().contains(Substring(String(appID)))
    }

    static func refresh(appID: Int) async throws {
        let id = UUID().uuidString
        let request = Paths.configDir.appendingPathComponent("hubcap-refresh.request")
        let ack = Paths.configDir.appendingPathComponent("hubcap-refresh.ack")
        try id.write(to: request, atomically: true, encoding: .utf8)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: notification as CFString), nil, nil, true)
        try await HubcapStoreBridge.querySubscription(appID)
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            if let value = try? String(contentsOf: ack, encoding: .utf8), value == id,
               isActive(appID) { return }
        }
        throw HubcapStoreError(message: "Lua and manifests are saved, but Steam has not confirmed activation. Launch Steam with this macSteam build and try again; downloads will be reused.")
    }
}
