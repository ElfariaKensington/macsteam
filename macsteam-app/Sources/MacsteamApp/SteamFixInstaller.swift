// Install a LuaTools "fix" ZIP into a Steam game folder, with local backups.
import CryptoKit
import Foundation

enum SteamFixInstallError: LocalizedError {
    case noInstallDir
    case badArchive
    case unsafeEntry(String)
    case failed(String)
    case notApplied
    case missingBackup(String)
    case modifiedSinceApply([String])

    var errorDescription: String? {
        switch self {
        case .noInstallDir:
            return "That game is not installed locally. Install it in Steam first."
        case .badArchive:
            return "The downloaded fix ZIP is damaged."
        case .unsafeEntry(let name):
            return "The fix ZIP contains an unsafe path: \(name)"
        case .failed(let detail):
            return "Couldn't install the fix: \(detail)"
        case .notApplied:
            return "That fix has no macSteam backup record."
        case .missingBackup(let path):
            return "The backup for \(path) is missing. macSteam left the game untouched."
        case .modifiedSinceApply(let paths):
            let sample = paths.prefix(3).joined(separator: ", ")
            let more = paths.count > 3 ? " (+\(paths.count - 3) more)" : ""
            return "These files changed after the fix was installed, so macSteam "
                + "left them alone: \(sample)\(more)."
        }
    }
}

struct SteamFixInstallResult {
    let added: Int
    let modified: Int
    let backupDir: URL
}

struct SteamFixRevertResult {
    let restored: Int
    let removed: Int
    let fixes: Int
}

struct SteamFixRecord: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let action: String
        let backup: String?
        let hashAfter: String?
    }

    let appID: Int
    let fixID: String
    let appliedAt: String
    let files: [Entry]

    private enum CodingKeys: String, CodingKey {
        case appID = "appid"
        case fixID = "fixid"
        case appliedAt
        case files
    }
}

struct SteamAppliedFix: Sendable, Identifiable {
    let fixID: String
    let appliedAt: Date?
    let added: Int
    let modified: Int
    let backupDir: URL

    var id: String { fixID }
    var fileCount: Int { added + modified }
}

enum SteamFixInstaller {
    private static let backupName = ".macsteam-fix"

    static func apply(zipData: Data,
                      appID: Int,
                      fixID: String,
                      installDir: URL) throws -> SteamFixInstallResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("macsteam-fix-\(UUID().uuidString)", isDirectory: true)
        try Paths.ensureDir(work)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("fix.zip")
        try zipData.write(to: zip, options: .atomic)
        let extract = work.appendingPathComponent("extracted", isDirectory: true)
        try Paths.ensureDir(extract)
        let unzip = Subprocess.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", extract.path])
        guard unzip.code == 0 else {
            throw SteamFixInstallError.failed(
                unzip.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let key = safeKey(fixID)
        let backupRoot = installDir
            .appendingPathComponent(backupName, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)

        let entries = try sourceFiles(in: extract)
        var applied: [(destination: URL, backup: URL?, existed: Bool)] = []
        var added = 0
        var modified = 0
        var record: [SteamFixRecord.Entry] = []

        do {
            for source in entries {
                let relative = source.relative
                let destination = installDir.appendingPathComponent(relative)
                let existed = fm.fileExists(atPath: destination.path)
                var backup: URL?
                if existed {
                    let bak = backupRoot.appendingPathComponent(relative + ".bak")
                    try Paths.ensureDir(bak.deletingLastPathComponent())
                    if !fm.fileExists(atPath: bak.path) {
                        try fm.copyItem(at: destination, to: bak)
                    }
                    backup = bak
                }
                try Paths.ensureDir(destination.deletingLastPathComponent())
                if existed { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source.url, to: destination)
                applied.append((destination, backup, existed))
                if existed { modified += 1 } else { added += 1 }
                record.append(SteamFixRecord.Entry(
                    path: relative,
                    action: existed ? "modified" : "added",
                    backup: backup?.path,
                    hashAfter: fileHash(destination)))
            }
        } catch {
            // Put the game folder back the way it was on a partial failure.
            for item in applied.reversed() {
                if let backup = item.backup {
                    try? fm.removeItem(at: item.destination)
                    try? fm.copyItem(at: backup, to: item.destination)
                } else {
                    try? fm.removeItem(at: item.destination)
                }
            }
            throw SteamFixInstallError.failed(error.localizedDescription)
        }

        let recordObject = SteamFixRecord(
            appID: appID,
            fixID: fixID,
            appliedAt: ISO8601DateFormatter().string(from: Date()),
            files: record)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recordObject)
            try Paths.ensureDir(backupRoot)
            try data.write(to: backupRoot.appendingPathComponent("record.json"),
                           options: .atomic)
        } catch {
            // Without the record the fix cannot be undone; put the game back.
            for item in applied.reversed() {
                if let backup = item.backup {
                    try? fm.removeItem(at: item.destination)
                    try? fm.copyItem(at: backup, to: item.destination)
                } else {
                    try? fm.removeItem(at: item.destination)
                }
            }
            throw SteamFixInstallError.failed(
                "Could not write the undo record: \(error.localizedDescription)")
        }

        return SteamFixInstallResult(added: added, modified: modified,
                                     backupDir: backupRoot)
    }

    static func appliedFixes(installDir: URL,
                             fm: FileManager = .default) -> [SteamAppliedFix] {
        let root = installDir.appendingPathComponent(backupName, isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: []) else { return [] }
        var out: [SteamAppliedFix] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            let recordURL = dir.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(SteamFixRecord.self, from: data)
            else { continue }
            out.append(SteamAppliedFix(
                fixID: record.fixID,
                appliedAt: ISO8601DateFormatter().date(from: record.appliedAt),
                added: record.files.filter { $0.action == "added" }.count,
                modified: record.files.filter { $0.action == "modified" }.count,
                backupDir: dir))
        }
        return out.sorted {
            ($0.appliedAt ?? .distantPast) > ($1.appliedAt ?? .distantPast)
        }
    }

    static func revert(installDir: URL, fixID: String, force: Bool = false,
                       fm: FileManager = .default) throws -> SteamFixRevertResult {
        let backupRoot = installDir
            .appendingPathComponent(backupName, isDirectory: true)
            .appendingPathComponent(safeKey(fixID), isDirectory: true)
        let recordURL = backupRoot.appendingPathComponent("record.json")
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(SteamFixRecord.self, from: data)
        else { throw SteamFixInstallError.notApplied }

        // Preflight everything before touching the game folder.
        var changed: [String] = []
        for entry in record.files {
            let destination = try destination(for: entry.path, installDir: installDir)
            if entry.action == "modified" {
                _ = try backupURL(entry, backupRoot: backupRoot, fm: fm)
            }
            if !force, let expected = entry.hashAfter, !expected.isEmpty,
               fm.fileExists(atPath: destination.path),
               fileHash(destination) != expected {
                changed.append(entry.path)
            }
        }
        guard changed.isEmpty else {
            throw SteamFixInstallError.modifiedSinceApply(changed)
        }

        var restored = 0
        var removed = 0
        for entry in record.files.reversed() {
            let destination = try destination(for: entry.path, installDir: installDir)
            switch entry.action {
            case "modified":
                let backup = try backupURL(entry, backupRoot: backupRoot, fm: fm)
                try Paths.ensureDir(destination.deletingLastPathComponent())
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: backup, to: destination)
                restored += 1
            case "added":
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                    removed += 1
                }
            default:
                break
            }
        }
        try? fm.removeItem(at: backupRoot)
        if let parent = try? fm.contentsOfDirectory(
            at: installDir.appendingPathComponent(backupName, isDirectory: true),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
            parent.isEmpty {
            try? fm.removeItem(at: installDir.appendingPathComponent(backupName,
                                                                     isDirectory: true))
        }
        return SteamFixRevertResult(restored: restored, removed: removed, fixes: 1)
    }

    static func revertAll(installDir: URL, force: Bool = false,
                          fm: FileManager = .default) throws -> SteamFixRevertResult {
        var restored = 0
        var removed = 0
        var fixes = 0
        for applied in appliedFixes(installDir: installDir, fm: fm) {
            let result = try revert(installDir: installDir, fixID: applied.fixID,
                                    force: force, fm: fm)
            restored += result.restored
            removed += result.removed
            fixes += 1
        }
        if fixes == 0 { throw SteamFixInstallError.notApplied }
        return SteamFixRevertResult(restored: restored, removed: removed, fixes: fixes)
    }

    private struct SourceFile {
        let url: URL
        let relative: String
    }

    private static func sourceFiles(in root: URL) throws -> [SourceFile] {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            throw SteamFixInstallError.badArchive
        }
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var out: [SourceFile] = []
        for case let url as URL in en {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard parts.count > rootParts.count,
                  Array(parts.prefix(rootParts.count)) == rootParts else { continue }
            let relative = parts.dropFirst(rootParts.count).joined(separator: "/")
            guard !relative.isEmpty,
                  !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains(".."),
                  !relative.hasPrefix("__MACOSX/"),
                  !relative.hasSuffix(".DS_Store") else {
                throw SteamFixInstallError.unsafeEntry(relative)
            }
            out.append(SourceFile(url: url, relative: relative))
        }
        guard !out.isEmpty else { throw SteamFixInstallError.badArchive }
        return out
    }

    private static func destination(for relative: String,
                                    installDir: URL) throws -> URL {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw SteamFixInstallError.unsafeEntry(relative)
        }
        return installDir.appendingPathComponent(relative)
    }

    private static func backupURL(_ entry: SteamFixRecord.Entry,
                                  backupRoot: URL,
                                  fm: FileManager) throws -> URL {
        let expected = backupRoot.appendingPathComponent(entry.path + ".bak")
        if fm.fileExists(atPath: expected.path) { return expected }
        if let recorded = entry.backup, !recorded.isEmpty {
            let url = URL(fileURLWithPath: recorded).standardizedFileURL
            let root = backupRoot.standardizedFileURL.path + "/"
            if url.path.hasPrefix(root), fm.fileExists(atPath: url.path) {
                return url
            }
        }
        throw SteamFixInstallError.missingBackup(entry.path)
    }

    private static func fileHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safeKey(_ fixID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_."))
        return String(fixID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
    }
}
