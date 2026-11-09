// Background runner for the cloud save mirror. Runs in both the config window and
// the headless Hubcap helper, so saves are restored even when the window is closed.
import Foundation

// MARK: - Logging

enum CloudSavesLog {
    static func write(_ message: String) {
        AppLog.write(message, category: "cloud-saves")
    }
}

@MainActor
final class CloudSavesRunner {
    static let shared = CloudSavesRunner()

    private var store: ConfigStore?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var isSyncing = false
    private var pendingSync = false

    private(set) var lastReport: CloudSavesReport?
    private(set) var lastSync: Date?

    var settings: CloudSavesSettings { CloudSavesSettings.load() }

    private init() {}

    func start(store: ConfigStore) {
        self.store = store
        Task.detached(priority: .utility) {
            CloudTokenStore.migrateFromKeychainIfNeeded()
        }
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.macsteam.cloudSavesChanged"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncNow() }
            }
        }
        scheduleTimer()
        if settings.enabled {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.syncNow()
            }
        }
    }

    func refreshSettings() {
        scheduleTimer()
        syncNow()
    }

    func syncNow(completion: (@MainActor (CloudSavesReport) -> Void)? = nil) {
        guard !isSyncing else {
            pendingSync = true
            completion?(lastReport ?? CloudSavesReport())
            return
        }
        let settings = self.settings
        guard settings.enabled, let syncRoot = settings.expandedSyncURL else {
            lastReport = nil
            completion?(CloudSavesReport())
            return
        }
        guard let store else {
            completion?(CloudSavesReport())
            return
        }
        store.reloadFromDisk()
        let allApps = Self.syncableApps(store: store)
        guard !allApps.isEmpty else {
            CloudSavesLog.write("Sync skipped: no games are added to macSteam.")
            lastReport = nil
            completion?(CloudSavesReport())
            return
        }
        let apps = Self.activeApps(allApps, store: store,
                                   disabled: settings.disabledApps)
        guard !apps.isEmpty else {
            CloudSavesLog.write("Sync paused: every configured game is disabled.")
            lastReport = nil
            completion?(CloudSavesReport())
            return
        }

        isSyncing = true
        let started = Date()
        let appNames = store.config.appNames
        CloudSavesLog.write("Sync started: provider=\(settings.provider.rawValue), "
                            + "apps=\(apps.count), paused=\(allApps.count - apps.count), "
                            + "cache=\(syncRoot.path)")

        Task.detached(priority: .utility) {
            let removedLocal = CloudSavesEngine.removeUnmanaged(syncRoot: syncRoot,
                                                                keeping: allApps)
            if !removedLocal.isEmpty {
                CloudSavesLog.write("Removed \(removedLocal.count) unmanaged game mirror(s) "
                                    + "from the local sync folder: "
                                    + removedLocal.joined(separator: ", "))
            }

            var report = CloudSavesEngine.sync(steamRoot: Paths.steamRoot,
                                               syncRoot: syncRoot,
                                               apps: apps)
            report.removed += removedLocal.count
            CloudSavesLog.write("Local mirror: \(report.summary) "
                                + "(accounts=\(report.accounts), apps=\(report.apps))")

            let remote = await CloudDriveSync.sync(settings: settings, apps: apps,
                                                   keepingApps: allApps)
            if settings.provider == .folder {
                CloudSavesLog.write("Provider: folder")
            } else {
                CloudSavesLog.write("Provider: \(remote.summary)")
                report.remoteSummary = remote.summary
                report.errors.append(contentsOf: remote.errors)
                // A provider download lands in the cache; mirror it to Steam now.
                let second = CloudSavesEngine.sync(steamRoot: Paths.steamRoot,
                                                   syncRoot: syncRoot,
                                                   apps: apps)
                CloudSavesLog.write("Local mirror after provider: \(second.summary)")
                report.copiedToLocal += second.copiedToLocal
                report.copiedToCloud += second.copiedToCloud
                report.conflicts += second.conflicts
                report.errors.append(contentsOf: second.errors)
                report.mergeGames(second.games)
            }
            report.applyNames(appNames)
            await MainActor.run {
                self.isSyncing = false
                self.lastReport = report
                self.lastSync = Date()
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                CloudSavesLog.write("Sync finished in \(elapsed)s: \(report.summary)")
                for error in report.errors.prefix(8) {
                    CloudSavesLog.write("  error: \(error)")
                }
                completion?(report)
                NotificationCenter.default.post(
                    name: Notification.Name("com.macsteam.cloudSavesSyncFinished"),
                    object: nil)
                if self.pendingSync {
                    self.pendingSync = false
                    Task { @MainActor in self.syncNow() }
                }
            }
        }
    }

    private static let ignoredApps: Set<Int> = [7, 480]

    /// Only games the user explicitly added to macSteam (config.yaml). Steam's own
    /// app (7) and Spacewar (480) are never synced even if they appear in config.
    private static func syncableApps(store: ConfigStore) -> Set<Int> {
        Set(store.config.apps.filter { $0 > 0 && !ignoredApps.contains($0) })
    }

    /// Pausing a base game also pauses its DLC appids. The files stay in the
    /// mirror and in Drive; only the sync passes skip them.
    static func activeApps(_ apps: Set<Int>, store: ConfigStore,
                           disabled: Set<Int>) -> Set<Int> {
        guard !disabled.isEmpty else { return apps }
        return apps.filter { app in
            var current = app
            var seen = Set<Int>()
            while let parent = store.config.appParents[current],
                  seen.insert(current).inserted {
                current = parent
            }
            return !disabled.contains(current)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard settings.enabled else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

}
