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
    case permissionDenied(String)

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
        case .permissionDenied(let path):
            return "macOS blocked macSteam from changing the game folder (\(path)). "
                + "Allow macSteam in Privacy & Security, then try again."
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
    /// Files left alone because they no longer match what the fix wrote (e.g. a game update).
    var skipped: [String] = []
}

/// How a recorded fix compares with the game folder right now.
enum SteamFixHealth: Equatable, Sendable {
    /// Every recorded file is still exactly what the fix wrote.
    case intact
    /// Some recorded files were changed (game update, manual edit) or deleted.
    case drifted(changed: [String], missing: [String])
    /// None of the recorded files exist any more: nothing left to undo.
    case gone
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
    var health: SteamFixHealth = .intact

    var id: String { fixID }
    var fileCount: Int { added + modified }
    var isDrifted: Bool { if case .drifted = health { return true } else { return false } }
}

enum SteamFixInstaller {
    private static let backupName = ".macsteam-fix"

    // MARK: - Permissions

    /// True for the errors macOS raises when privacy protection (Files and Folders, Removable
    /// Volumes, Full Disk Access, App Management) or file permissions block a write.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, underlying as NSError !== ns {
            return isPermissionError(underlying)
        }
        return false
    }

    /// Fails early, before anything is downloaded, when macOS will not let us write into the
    /// game folder. Touching the folder also makes macOS show its own permission prompt where
    /// one exists (removable and network volumes, Desktop/Documents/Downloads).
    static func ensureWritable(installDir: URL, fm: FileManager = .default) throws {
        let probe = installDir.appendingPathComponent(".macsteam-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
        } catch {
            if isPermissionError(error) { throw SteamFixInstallError.permissionDenied(installDir.path) }
            throw SteamFixInstallError.failed(error.localizedDescription)
        }
    }

    // MARK: - Install

    static func apply(zipData: Data,
                      appID: Int,
                      fixID: String,
                      installDir: URL) throws -> SteamFixInstallResult {
        let fm = FileManager.default
        try ensureWritable(installDir: installDir, fm: fm)
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

        // Reinstalling over an earlier install (for example after a game update replaced some
        // of the fix's files): files already in the record keep their original action and
        // backup, so Undo still returns the game to its pre-fix state.
        let previous = loadRecord(backupRoot: backupRoot)
        let previousByPath = Dictionary(
            (previous?.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        let entries = try sourceFiles(in: extract)
        let snapshotRoot = work.appendingPathComponent("rollback", isDirectory: true)
        var touched: [(destination: URL, snapshot: URL?)] = []
        var added = 0
        var modified = 0
        var record: [SteamFixRecord.Entry] = []
        var written = Set<String>()

        func rollback() {
            for item in touched.reversed() {
                try? fm.removeItem(at: item.destination)
                if let snapshot = item.snapshot { try? fm.copyItem(at: snapshot, to: item.destination) }
            }
        }

        do {
            for source in entries {
                let relative = source.relative
                let destination = installDir.appendingPathComponent(relative)
                let existed = fm.fileExists(atPath: destination.path)
                let earlier = previousByPath[relative]
                var backup: URL?
                var action = existed ? "modified" : "added"
                if let earlier {
                    // Keep the first install's view of this file.
                    action = earlier.action
                    if let recorded = earlier.backup, !recorded.isEmpty { backup = URL(fileURLWithPath: recorded) }
                } else if existed {
                    let bak = backupRoot.appendingPathComponent(relative + ".bak")
                    try Paths.ensureDir(bak.deletingLastPathComponent())
                    if !fm.fileExists(atPath: bak.path) { try fm.copyItem(at: destination, to: bak) }
                    backup = bak
                }
                var snapshot: URL?
                if existed {
                    let snap = snapshotRoot.appendingPathComponent(relative)
                    try Paths.ensureDir(snap.deletingLastPathComponent())
                    try fm.copyItem(at: destination, to: snap)
                    snapshot = snap
                }
                touched.append((destination, snapshot))
                try Paths.ensureDir(destination.deletingLastPathComponent())
                if existed { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source.url, to: destination)
                if action == "modified" { modified += 1 } else { added += 1 }
                written.insert(relative)
                record.append(SteamFixRecord.Entry(
                    path: relative, action: action, backup: backup?.path,
                    hashAfter: fileHash(destination)))
            }
        } catch {
            rollback()
            if isPermissionError(error) { throw SteamFixInstallError.permissionDenied(installDir.path) }
            throw SteamFixInstallError.failed(error.localizedDescription)
        }
        // Files an earlier install recorded that this ZIP no longer contains stay undoable.
        for entry in previous?.files ?? [] where !written.contains(entry.path) {
            record.append(entry)
            if entry.action == "modified" { modified += 1 } else { added += 1 }
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
            rollback()
            if isPermissionError(error) { throw SteamFixInstallError.permissionDenied(installDir.path) }
            throw SteamFixInstallError.failed(
                "Could not write the undo record: \(error.localizedDescription)")
        }

        return SteamFixInstallResult(added: added, modified: modified,
                                     backupDir: backupRoot)
    }

    // MARK: - State

    private static func loadRecord(backupRoot: URL) -> SteamFixRecord? {
        guard let data = try? Data(contentsOf: backupRoot.appendingPathComponent("record.json")),
              let record = try? JSONDecoder().decode(SteamFixRecord.self, from: data) else { return nil }
        return record
    }

    /// Compares a record with the game folder: which recorded files still match what the fix
    /// wrote, which changed, which are gone.
    static func health(of record: SteamFixRecord, installDir: URL,
                       fm: FileManager = .default) -> SteamFixHealth {
        var changed: [String] = []
        var missing: [String] = []
        var present = 0
        for entry in record.files {
            let url = installDir.appendingPathComponent(entry.path)
            guard fm.fileExists(atPath: url.path) else { missing.append(entry.path); continue }
            present += 1
            if let expected = entry.hashAfter, !expected.isEmpty, fileHash(url) != expected {
                changed.append(entry.path)
            }
        }
        if present == 0 { return .gone }
        return changed.isEmpty && missing.isEmpty ? .intact : .drifted(changed: changed, missing: missing)
    }

    /// Fixes that are really present in the game folder. A fix whose files were all deleted
    /// (the game was removed or wiped by hand) is dropped, with its record and backups, so no
    /// stale Undo is offered. A fix with some changed or missing files is returned as drifted.
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
            guard let record = loadRecord(backupRoot: dir) else { continue }
            let health = health(of: record, installDir: installDir, fm: fm)
            if health == .gone {
                try? fm.removeItem(at: dir)
                continue
            }
            out.append(SteamAppliedFix(
                fixID: record.fixID,
                appliedAt: ISO8601DateFormatter().date(from: record.appliedAt),
                added: record.files.filter { $0.action == "added" }.count,
                modified: record.files.filter { $0.action == "modified" }.count,
                backupDir: dir,
                health: health))
        }
        if let rest = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]), rest.isEmpty {
            try? fm.removeItem(at: root)
        }
        return out.sorted {
            ($0.appliedAt ?? .distantPast) > ($1.appliedAt ?? .distantPast)
        }
    }

    // MARK: - Undo

    /// Strict undo: refuses when any recorded file changed after the fix was installed, unless
    /// `force` is set. Use `revertSafely` for a drifted fix.
    static func revert(installDir: URL, fixID: String, force: Bool = false,
                       fm: FileManager = .default) throws -> SteamFixRevertResult {
        let backupRoot = installDir
            .appendingPathComponent(backupName, isDirectory: true)
            .appendingPathComponent(safeKey(fixID), isDirectory: true)
        guard let record = loadRecord(backupRoot: backupRoot) else { throw SteamFixInstallError.notApplied }
        try ensureWritable(installDir: installDir, fm: fm)

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
        do {
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
        } catch {
            if isPermissionError(error) { throw SteamFixInstallError.permissionDenied(installDir.path) }
            throw error
        }
        cleanUp(backupRoot: backupRoot, installDir: installDir, fm: fm)
        return SteamFixRevertResult(restored: restored, removed: removed, fixes: 1)
    }

    /// Undo for a fix whose files changed or disappeared (a game update overwrote some of them,
    /// the user deleted some). Only files that are still exactly what the fix wrote are
    /// restored/removed; anything else is the game's own and is left alone. Never throws for
    /// drift, and always clears the fix record, so the fix can be installed again.
    static func revertSafely(installDir: URL, fixID: String,
                             fm: FileManager = .default) throws -> SteamFixRevertResult {
        let backupRoot = installDir
            .appendingPathComponent(backupName, isDirectory: true)
            .appendingPathComponent(safeKey(fixID), isDirectory: true)
        guard let record = loadRecord(backupRoot: backupRoot) else { throw SteamFixInstallError.notApplied }
        try ensureWritable(installDir: installDir, fm: fm)
        var restored = 0
        var removed = 0
        var skipped: [String] = []
        do {
            for entry in record.files.reversed() {
                let destination = try destination(for: entry.path, installDir: installDir)
                let exists = fm.fileExists(atPath: destination.path)
                let ours = exists && (entry.hashAfter?.isEmpty != false || fileHash(destination) == entry.hashAfter)
                if exists && !ours { skipped.append(entry.path); continue }
                switch entry.action {
                case "modified":
                    // Missing original backup: nothing we can restore, leave the file as is.
                    guard let backup = try? backupURL(entry, backupRoot: backupRoot, fm: fm) else {
                        if exists { skipped.append(entry.path) }
                        continue
                    }
                    if !exists { continue }   // the user deleted it; do not resurrect it
                    try fm.removeItem(at: destination)
                    try fm.copyItem(at: backup, to: destination)
                    restored += 1
                case "added":
                    if exists { try fm.removeItem(at: destination); removed += 1 }
                default:
                    break
                }
            }
        } catch {
            if isPermissionError(error) { throw SteamFixInstallError.permissionDenied(installDir.path) }
            throw error
        }
        cleanUp(backupRoot: backupRoot, installDir: installDir, fm: fm)
        return SteamFixRevertResult(restored: restored, removed: removed, fixes: 1, skipped: skipped)
    }

    private static func cleanUp(backupRoot: URL, installDir: URL, fm: FileManager) {
        try? fm.removeItem(at: backupRoot)
        let root = installDir.appendingPathComponent(backupName, isDirectory: true)
        if let rest = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]), rest.isEmpty {
            try? fm.removeItem(at: root)
        }
    }

    static func revertAll(installDir: URL, force: Bool = false,
                          fm: FileManager = .default) throws -> SteamFixRevertResult {
        var restored = 0
        var removed = 0
        var fixes = 0
        var skipped: [String] = []
        for applied in appliedFixes(installDir: installDir, fm: fm) {
            // A drifted fix cannot be undone strictly; undo what still belongs to it.
            let result = (applied.isDrifted || force)
                ? try revertSafely(installDir: installDir, fixID: applied.fixID, fm: fm)
                : try revert(installDir: installDir, fixID: applied.fixID, force: false, fm: fm)
            restored += result.restored
            removed += result.removed
            skipped += result.skipped
            fixes += 1
        }
        if fixes == 0 { throw SteamFixInstallError.notApplied }
        return SteamFixRevertResult(restored: restored, removed: removed, fixes: fixes, skipped: skipped)
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
