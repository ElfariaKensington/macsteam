// Turn off Steam's native per-game cloud switch for macSteam-unlocked games.
//
// Steam's cloud backend denies uploads ("Access Denied") when the account does
// not own the app. The client then reports SyncFailed, which shows "Unable to
// sync" in the library and a cloud sync failed dialog on launch. macSteam's own
// Cloud Saves mirror handles saves instead, so the native switch is disabled for
// unlocked games. Genuinely owned games keep native cloud.
import AppKit
import Foundation

enum SteamCloudLog {
    static func write(_ message: String) {
        AppLog.write(message, category: "cloud")
    }
}

enum CloudErrorPolicy {
    /// EAppCloudStatus: 1 = disabled, 8 = sync failed.
    static func shouldDisable(freeRemovableLicense: Bool,
                              cloudEnabled: Bool,
                              status: Int) -> Bool {
        guard cloudEnabled, freeRemovableLicense else { return false }
        return status != 1
    }
}

@MainActor
final class SteamCloudBridge {
    static let shared = SteamCloudBridge()

    private var store: ConfigStore?
    private var page: CDPPage?
    private var loopTask: Task<Void, Never>?
    private var started = false
    private var syncedApps: Set<Int> = []
    private var syncedEnabled: Bool?
    private var disabledApps = Set<Int>()
    private var lastConfigReload = Date.distantPast
    private var retryAfter = Date.distantPast
    private let debugSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    private init() {}

    func start(store: ConfigStore) {
        self.store = store
        guard !started else { return }
        started = true
        SteamCloudLog.write("cloud: bridge started")
        loopTask = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func poll() async {
        guard let tabs = await fetchTabs() else { return }
        guard let tab = tabs.first(where: { $0.title == "SharedJSContext" }),
              let id = tab.id,
              let wsString = tab.webSocketDebuggerURL,
              let wsURL = URL(string: wsString) else {
            if let page {
                await page.close()
                self.page = nil
                syncedApps.removeAll()
                syncedEnabled = nil
            }
            return
        }

        if let page, await page.isClosed() {
            self.page = nil
            syncedApps.removeAll()
            syncedEnabled = nil
        }
        if page == nil {
            if Date() >= retryAfter {
                await attach(tabID: id, wsURL: wsURL)
            }
        }
        await syncApps()
    }

    private func attach(tabID: String, wsURL: URL) async {
        let page: CDPPage
        do {
            page = try CDPPage(tabID: tabID, webSocketURL: wsURL)
        } catch {
            SteamCloudLog.write("cloud: invalid Steam UI target: \(error.localizedDescription)")
            return
        }
        do {
            try await page.start { [weak self] name, payload in
                guard name == "macsteamCloud" else { return }
                await self?.handleMessage(payload)
            }
            self.page = page
            try await page.addBinding(name: "macsteamCloud")
            let script = try await Task.detached(priority: .utility) {
                try Self.cloudScript()
            }.value
            try await page.addStartupScript(script)
            try await page.evaluate(script)
            syncedApps.removeAll()
            syncedEnabled = nil
            retryAfter = .distantPast
            SteamCloudLog.write("cloud: attached to Steam UI")
        } catch {
            self.page = nil
            await page.close()
            retryAfter = Date().addingTimeInterval(30)
            SteamCloudLog.write("cloud: attach failed: \(error.localizedDescription)")
        }
    }

    private func syncApps() async {
        guard let store, let page, !(await page.isClosed()) else { return }
        if Date().timeIntervalSince(lastConfigReload) > 5 {
            lastConfigReload = Date()
            store.reloadFromDisk()
        }
        let enabled = store.config.hideCloudErrors
        let apps = store.config.topLevelApps
        let ids = Set(apps)
        let changed = ids != syncedApps || enabled != syncedEnabled
        syncedApps = ids
        syncedEnabled = enabled
        let list = apps.map(String.init).joined(separator: ",")
        do {
            // Re-send every poll: SteamUI can reload SharedJSContext without closing
            // the debugger target, and the agent's registrations do not survive that.
            try await page.evaluate(
                "window.__macsteamCloud && window.__macsteamCloud.sync([\(list)], "
                + "\(enabled ? "true" : "false"))")
            if changed {
                SteamCloudLog.write(
                    "cloud: \(enabled ? "watching" : "idle") \(apps.count) config game(s)")
            }
        } catch {
            syncedApps.removeAll()
            syncedEnabled = nil
            SteamCloudLog.write("cloud: sync failed: \(error.localizedDescription)")
        }
    }

    private func handleMessage(_ payload: String) async {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appID = root["appid"] as? Int,
              let cloudEnabled = root["cloudEnabled"] as? Bool,
              let freeRemovable = root["freeRemovable"] as? Bool,
              let status = root["status"] as? Int,
              appID > 0 else { return }
        guard store?.config.hideCloudErrors == true,
              store?.config.topLevelApps.contains(appID) == true,
              CloudErrorPolicy.shouldDisable(freeRemovableLicense: freeRemovable,
                                             cloudEnabled: cloudEnabled,
                                             status: status) else { return }
        // Respect a user who turns the switch back on unless Steam failed again.
        if disabledApps.contains(appID), status != 8 { return }
        guard let page, !(await page.isClosed()) else { return }
        do {
            try await page.evaluate("SteamClient.Apps.ToggleAppSteamCloudEnabled(\(appID))")
            disabledApps.insert(appID)
            SteamCloudLog.write("cloud: disabled native cloud for app \(appID)")
        } catch {
            SteamCloudLog.write(
                "cloud: disabling app \(appID) failed: \(error.localizedDescription)")
        }
    }

    private func fetchTabs() async -> [CDPTab]? {
        guard let url = URL(string: "http://127.0.0.1:8080/json/list") else { return nil }
        do {
            let (data, response) = try await debugSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode([CDPTab].self, from: data)
        } catch {
            return nil
        }
    }

    nonisolated private static func cloudScript() throws -> String {
        var candidates: [URL] = []
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "steam-cloud", withExtension: "js") {
            candidates.append(url)
        }
        #endif
        if let url = Bundle.main.url(forResource: "steam-cloud", withExtension: "js") {
            candidates.append(url)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(
                "MacsteamApp_MacsteamApp.bundle/steam-cloud.js"))
            candidates.append(resources.appendingPathComponent("steam-cloud.js"))
        }
        for url in candidates {
            if let script = try? String(contentsOf: url, encoding: .utf8), !script.isEmpty {
                return script
            }
        }
        throw CDPError.badResponse("Steam cloud script is missing from the app.")
    }
}
