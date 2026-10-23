// Config store
import Foundation
import CryptoKit

final class ConfigStore {
    private(set) var config = MacsteamConfig()

    private let configFile: URL
    private let backupDir: URL

    private var lastKnownHash: String?

    init(configFile: URL = Paths.configFile, backupDir: URL = Paths.configBackupDir) {
        self.configFile = configFile
        self.backupDir = backupDir
    }

    static let headerText: String? = nil

    private static let backupsToKeep = 10

    func load() {
        if let text = try? String(contentsOf: configFile, encoding: .utf8) {
            config = MacsteamConfig.parse(text)
            lastKnownHash = Self.hash(text)
        } else {
            config = MacsteamConfig()
            config.packageIds = [Paths.defaultInjectionPackage]
            lastKnownHash = nil
        }
    }

    func mutate(_ change: (inout MacsteamConfig) -> Void) throws {
        reconcileWithDiskIfChanged()
        change(&config)
        try writeAtomically()
    }

    func removeApps(_ ids: [Int]) throws {
        try mutate { $0.removeApps(ids) }
    }

    func setHideWhatsNew(_ on: Bool) throws {
        try mutate { $0.hideWhatsNew = on }
    }

    func setHideCloudErrors(_ on: Bool) throws {
        try mutate { $0.hideCloudErrors = on }
    }

    // MARK: - conflict + backup internals

    private func reconcileWithDiskIfChanged() {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return }
        let onDisk = Self.hash(text)
        if onDisk == lastKnownHash { return }
        config = MacsteamConfig.parse(text)
        lastKnownHash = onDisk
    }

    private func writeAtomically() throws {
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        backupCurrentFile()
        let text = config.serialize(header: Self.headerText)
        try text.write(to: configFile, atomically: true, encoding: .utf8)
        lastKnownHash = Self.hash(text)
    }

    private func backupCurrentFile() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configFile.path) else { return }
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970)
        var dest = backupDir.appendingPathComponent("config.yaml.\(ts).bak")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = backupDir.appendingPathComponent("config.yaml.\(ts)-\(n).bak")
            n += 1
        }
        try? fm.copyItem(at: configFile, to: dest)
        pruneBackups(in: backupDir)
    }

    private func pruneBackups(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let backups = entries.filter { $0.lastPathComponent.hasSuffix(".bak") }
        guard backups.count > Self.backupsToKeep else { return }
        let sorted = backups.sorted {
            let a = fileModified($0) ?? .distantPast
            let b = fileModified($1) ?? .distantPast
            if a != b { return a > b }
            return $0.lastPathComponent > $1.lastPathComponent
        }
        for old in sorted.dropFirst(Self.backupsToKeep) { try? fm.removeItem(at: old) }
    }

    private func fileModified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
