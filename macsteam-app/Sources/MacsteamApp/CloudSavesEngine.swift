// Cloud save mirroring for injected games.
//
// This is macSteam's macOS take on CloudRedirect's "folder" provider: Steam still
// owns userdata/<account>/<appid>/remote, and we mirror that directory tree to a
// folder the user can place inside iCloud Drive, Dropbox, etc.
// Files are copied both ways; the newest copy wins and the older one is backed up.
import Darwin
import Foundation

enum CloudSavesProvider: String, Codable, CaseIterable, Sendable {
    case folder
    case gdrive

    var title: String {
        switch self {
        case .folder: return "Folder / synced folder"
        case .gdrive: return "Google Drive"
        }
    }
}

struct CloudSavesSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var provider: CloudSavesProvider = .folder
    var syncPath: String = ""
    /// Top-level config games the user paused. Their mirrored files are left in
    /// place, but the engine and Drive provider stop updating them.
    var disabledApps: Set<Int> = []

    static let defaultsKey = "cloudSavesSettings"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let rawProvider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "folder"
        provider = CloudSavesProvider(rawValue: rawProvider) ?? .folder
        syncPath = try c.decodeIfPresent(String.self, forKey: .syncPath) ?? ""
        let paused = try c.decodeIfPresent([Int].self, forKey: .disabledApps) ?? []
        disabledApps = Set(paused)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, syncPath, disabledApps
    }

    static func load() -> CloudSavesSettings {
        // The headless helper reads settings written by the config window in another
        // process; force cfprefsd to hand us the current values.
        UserDefaults.standard.synchronize()
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(CloudSavesSettings.self, from: data) else {
            return CloudSavesSettings()
        }
        return settings
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    var expandedSyncURL: URL? {
        switch provider {
        case .folder:
            let raw = (syncPath as NSString).expandingTildeInPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            return URL(fileURLWithPath: raw, isDirectory: true)
        case .gdrive:
            return Paths.cloudSavesCacheDir
        }
    }
}

struct CloudSavesGameSync: Sendable, Identifiable, Equatable {
    let appID: Int
    var name = ""
    var files = 0
    var copiedToCloud = 0
    var copiedToLocal = 0
    var conflicts = 0
    var errors: [String] = []

    var id: Int { appID }
    var isSuccess: Bool { errors.isEmpty }

    var displayName: String {
        name.isEmpty ? "App \(appID)" : name
    }

    var statusText: String {
        if let error = errors.first {
            return errors.count == 1 ? "Failed · \(error)" : "Failed · \(errors.count) errors"
        }
        var parts: [String] = []
        if copiedToCloud > 0 { parts.append("\(copiedToCloud) up") }
        if copiedToLocal > 0 { parts.append("\(copiedToLocal) down") }
        if conflicts > 0 {
            parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s")")
        }
        let action = parts.isEmpty ? "Up to date" : "Synced"
        var text = "\(action) · \(files) file\(files == 1 ? "" : "s")"
        if !parts.isEmpty { text += " · " + parts.joined(separator: " · ") }
        return text
    }

    mutating func merge(_ other: CloudSavesGameSync) {
        files = max(files, other.files)
        copiedToCloud += other.copiedToCloud
        copiedToLocal += other.copiedToLocal
        conflicts += other.conflicts
        for error in other.errors where !errors.contains(error) {
            errors.append(error)
        }
    }
}

struct CloudSavesReport: Sendable {
    var copiedToCloud = 0
    var copiedToLocal = 0
    var conflicts = 0
    var skipped = 0
    var removed = 0
    var errors: [String] = []
    var accounts = 0
    var apps = 0
    var remoteSummary: String?
    var games: [CloudSavesGameSync] = []

    var summary: String {
        if !errors.isEmpty {
            return "\(copiedToCloud + copiedToLocal) synced, \(errors.count) error\(errors.count == 1 ? "" : "s")"
        }
        var text = "Local: \(copiedToCloud) up · \(copiedToLocal) down"
        if conflicts > 0 { text += " · \(conflicts) conflict\(conflicts == 1 ? "" : "s")" }
        if removed > 0 { text += " · \(removed) removed" }
        if let remoteSummary { text += " · \(remoteSummary)" }
        return text
    }

    mutating func mergeGames(_ incoming: [CloudSavesGameSync]) {
        var byID = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0) })
        for game in incoming {
            if var existing = byID[game.appID] {
                existing.merge(game)
                byID[game.appID] = existing
            } else {
                byID[game.appID] = game
            }
        }
        games = byID.values.sorted { $0.appID < $1.appID }
    }

    mutating func applyNames(_ names: [Int: String]) {
        for index in games.indices {
            if let name = names[games[index].appID], !name.isEmpty {
                games[index].name = name
            }
        }
    }
}

enum CloudSavesEngine {
    private static let excludedNames: Set<String> = [
        ".DS_Store", "remotecache.vdf",
    ]
    private static let maxConflictBackups = 300
    // Steam's own cloud folder, plus the CrossOver/Windows game save folder
    // Steam creates for some titles (Cult of the Lamb, for example).
    static let saveRoots = ["remote", "ac/GameInstall/saves"]

    static func sync(steamRoot: URL,
                     syncRoot: URL,
                     apps: Set<Int>,
                     fileManager fm: FileManager = .default) -> CloudSavesReport {
        var report = CloudSavesReport()
        guard !apps.isEmpty else { return report }

        let lockURL = Paths.cloudSavesLock
        try? fm.createDirectory(at: lockURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            report.skipped = 1
            return report
        }
        defer { if fd >= 0 { close(fd) } }

        do {
            try fm.createDirectory(at: syncRoot, withIntermediateDirectories: true)
        } catch {
            report.errors.append("Could not create sync folder: \(error.localizedDescription)")
            return report
        }

        let userdata = steamRoot.appendingPathComponent("userdata", isDirectory: true)
        var accountNames = Set<String>()
        for root in [userdata, syncRoot] {
            let entries = (try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            for entry in entries where isNumericName(entry.lastPathComponent) &&
                entry.lastPathComponent != "0" &&
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                accountNames.insert(entry.lastPathComponent)
            }
        }
        var games: [Int: CloudSavesGameSync] = [:]
        for accountName in accountNames.sorted() {
            report.accounts += 1
            for app in apps {
                let localApp = userdata
                    .appendingPathComponent(accountName, isDirectory: true)
                    .appendingPathComponent(String(app), isDirectory: true)
                let cloudApp = syncRoot
                    .appendingPathComponent(accountName, isDirectory: true)
                    .appendingPathComponent(String(app), isDirectory: true)

                let existingRoots = saveRoots.filter { root in
                    fm.fileExists(atPath: localApp.appendingPathComponent(root).path)
                        || fm.fileExists(atPath: cloudApp.appendingPathComponent(root).path)
                }
                guard !existingRoots.isEmpty else { continue }
                report.apps += 1

                var game = CloudSavesGameSync(appID: app)
                for root in existingRoots {
                    let local = localApp.appendingPathComponent(root, isDirectory: true)
                    let cloud = cloudApp.appendingPathComponent(root, isDirectory: true)
                    do {
                        try fm.createDirectory(at: local, withIntermediateDirectories: true)
                        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
                    } catch {
                        let message = "\(accountName)/\(app)/\(root): "
                            + error.localizedDescription
                        report.errors.append(message)
                        game.errors.append(message)
                        continue
                    }
                    syncTree(local: local, cloud: cloud,
                             account: accountName, app: app,
                             syncRoot: syncRoot, game: &game,
                             report: &report, fm: fm)
                }
                if var existing = games[app] {
                    existing.merge(game)
                    games[app] = existing
                } else {
                    games[app] = game
                }
            }
        }
        report.games = games.values.sorted { $0.appID < $1.appID }
        pruneConflictBackups(syncRoot: syncRoot, report: &report, fm: fm)
        return report
    }

    /// Move mirrored games that are no longer added to macSteam out of the sync
    /// folder. They are kept under `.macsteam-removed` so nothing is lost, and the
    /// hidden folder is ignored by both the local mirror and Google Drive sync.
    static func removeUnmanaged(syncRoot: URL,
                                keeping apps: Set<Int>,
                                fm: FileManager = .default) -> [String] {
        guard let accounts = try? fm.contentsOfDirectory(
            at: syncRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantine = syncRoot
            .appendingPathComponent(".macsteam-removed", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)

        var removed: [String] = []
        for account in accounts {
            let accountValues = try? account.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard account.lastPathComponent.allSatisfy(\.isNumber),
                  account.lastPathComponent != "0",
                  accountValues?.isDirectory == true,
                  accountValues?.isSymbolicLink != true else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: account, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                guard let appID = Int(entry.lastPathComponent), appID > 0,
                      !apps.contains(appID) else { continue }
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true,
                      fm.fileExists(atPath: entry.appendingPathComponent(
                        "remote", isDirectory: true).path) else { continue }

                let destination = quarantine
                    .appendingPathComponent(account.lastPathComponent, isDirectory: true)
                    .appendingPathComponent(String(appID), isDirectory: true)
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: entry, to: destination)
                    removed.append("\(account.lastPathComponent)/\(appID)")
                } catch {
                    // Leave it for the next sync rather than failing the whole run.
                }
            }
            if let remaining = try? fm.contentsOfDirectory(atPath: account.path),
               remaining.isEmpty {
                try? fm.removeItem(at: account)
            }
        }
        return removed
    }

    // MARK: - Tree sync

    private static func syncTree(local: URL, cloud: URL,
                                 account: String, app: Int,
                                 syncRoot: URL, game: inout CloudSavesGameSync,
                                 report: inout CloudSavesReport,
                                 fm: FileManager) {
        let localFiles = files(in: local, fm: fm)
        let cloudFiles = files(in: cloud, fm: fm)
        game.files += localFiles.union(cloudFiles).count

        for relative in localFiles.union(cloudFiles) {
            let localURL = local.appendingPathComponent(relative)
            let cloudURL = cloud.appendingPathComponent(relative)

            let localAttrs = attrs(localURL, fm: fm)
            let cloudAttrs = attrs(cloudURL, fm: fm)

            do {
                if localAttrs == nil, let cloudAttrs {
                    try ensureParent(localURL, fm: fm)
                    try copy(cloudURL, to: localURL, mtime: cloudAttrs.mtime, fm: fm)
                    report.copiedToLocal += 1
                    game.copiedToLocal += 1
                } else if cloudAttrs == nil, let localAttrs {
                    try ensureParent(cloudURL, fm: fm)
                    try copy(localURL, to: cloudURL, mtime: localAttrs.mtime, fm: fm)
                    report.copiedToCloud += 1
                    game.copiedToCloud += 1
                } else if let localAttrs, let cloudAttrs {
                    if localAttrs.size == cloudAttrs.size &&
                        abs(localAttrs.mtime - cloudAttrs.mtime) < 2 {
                        report.skipped += 1
                        continue
                    }
                    if localAttrs.mtime >= cloudAttrs.mtime {
                        try backupConflict(cloudURL, relative: relative, account: account,
                                           app: app, syncRoot: syncRoot, fm: fm)
                        try copy(localURL, to: cloudURL, mtime: localAttrs.mtime, fm: fm)
                        report.copiedToCloud += 1
                        game.copiedToCloud += 1
                    } else {
                        try backupConflict(localURL, relative: relative, account: account,
                                           app: app, syncRoot: syncRoot, fm: fm)
                        try copy(cloudURL, to: localURL, mtime: cloudAttrs.mtime, fm: fm)
                        report.copiedToLocal += 1
                        game.copiedToLocal += 1
                    }
                    report.conflicts += 1
                    game.conflicts += 1
                }
            } catch {
                let message = "\(account)/\(app)/\(relative): \(error.localizedDescription)"
                report.errors.append(message)
                game.errors.append(message)
            }
        }
    }

    private struct FileAttrs {
        let size: Int
        let mtime: TimeInterval
    }

    private static func attrs(_ url: URL, fm: FileManager) -> FileAttrs? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ]), values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        return FileAttrs(size: values.fileSize ?? 0,
                         mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    private static func files(in root: URL, fm: FileManager) -> Set<String> {
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var out = Set<String>()
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if excludedNames.contains(name) || name.hasSuffix(".tmp") { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // enumerator URLs may resolve /var -> /private/var while the root did not.
            let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let fileParts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard fileParts.count > rootParts.count,
                  Array(fileParts.prefix(rootParts.count)) == rootParts else { continue }
            let rel = fileParts.dropFirst(rootParts.count).joined(separator: "/")
            guard !rel.isEmpty, !rel.split(separator: "/").contains("..") else { continue }
            out.insert(rel)
        }
        return out
    }

    private static func ensureParent(_ url: URL, fm: FileManager) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
    }

    private static func copy(_ src: URL, to dst: URL, mtime: TimeInterval,
                             fm: FileManager) throws {
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".macsteam-\(UUID().uuidString).tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        if fm.fileExists(atPath: dst.path) {
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dst)
        }
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                              ofItemAtPath: dst.path)
    }

    private static func backupConflict(_ url: URL, relative: String, account: String,
                                       app: Int, syncRoot: URL, fm: FileManager) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = syncRoot
            .appendingPathComponent(".conflicts", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
            .appendingPathComponent(account, isDirectory: true)
            .appendingPathComponent(String(app), isDirectory: true)
            .appendingPathComponent(relative)
        try ensureParent(backup, fm: fm)
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: url, to: backup)
    }

    private static func pruneConflictBackups(syncRoot: URL, report: inout CloudSavesReport,
                                             fm: FileManager) {
        let root = syncRoot.appendingPathComponent(".conflicts", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]),
              dirs.count > maxConflictBackups else { return }
        let sorted = dirs.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast)
        }
        for old in sorted.dropFirst(maxConflictBackups) {
            try? fm.removeItem(at: old)
        }
    }

    private static func isNumericName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isNumber }
    }
}
