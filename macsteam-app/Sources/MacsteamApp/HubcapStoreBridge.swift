// Injects the macSteam store button through Steam's CEF debugging port.
//
// Steam only opens the port when .cef-enable-remote-debugging exists at launch, so the
// dylib spawns this app with --hubcap-store-bridge and we keep the marker in place.
// The config app can also run this bridge itself when it is open.
import AppKit
import Darwin
import Foundation

// MARK: - Logging

enum HubcapLog {
    static func write(_ message: String) {
        AppLog.write(message, category: "hubcap")
    }
}

// MARK: - CDP connection

enum CDPError: LocalizedError {
    case disconnected
    case badResponse(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Steam's store page closed the connection."
        case .badResponse(let detail): return "Steam returned an unexpected CDP response: \(detail)"
        case .command(let detail): return "Steam rejected a CDP command: \(detail)"
        }
    }
}

actor CDPPage {
    let tabID: String
    private let socket: CEFWebSocket
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var closed = false
    private var onBindingMessage: (@Sendable (String, String) async -> Void)?

    init(tabID: String, webSocketURL: URL) throws {
        guard let host = webSocketURL.host,
              let port = UInt16(exactly: webSocketURL.port ?? 80) else {
            throw CDPError.badResponse("Invalid CEF WebSocket URL")
        }
        var path = webSocketURL.path
        if let query = webSocketURL.query { path += "?" + query }
        self.tabID = tabID
        self.socket = CEFWebSocket(host: host, port: port, path: path)
    }

    func start(onBindingMessage: @escaping @Sendable (String, String) async -> Void) async throws {
        self.onBindingMessage = onBindingMessage
        socket.onText = { [weak self] text in
            Task { await self?.handleText(text) }
        }
        socket.onClose = { [weak self] error in
            Task { await self?.connectionClosed(error) }
        }
        try await socket.start()
        _ = try? await send(method: "Page.enable")
        _ = try? await send(method: "Runtime.enable")
    }

    func addBinding(name: String) async throws {
        _ = try await send(method: "Runtime.addBinding", params: ["name": name])
    }

    func addStartupScript(_ source: String) async throws {
        _ = try await send(method: "Page.addScriptToEvaluateOnNewDocument",
                           params: ["source": source])
    }

    func reload() async throws {
        _ = try await send(method: "Page.reload", params: ["ignoreCache": false])
    }

    func evaluate(_ expression: String) async throws {
        _ = try await send(method: "Runtime.evaluate",
                           params: ["expression": expression, "returnByValue": true])
    }

    func evaluateString(_ expression: String) async throws -> String? {
        let data = try await send(method: "Runtime.evaluate",
                                  params: ["expression": expression, "returnByValue": true])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let value = result["value"] as? String else { return nil }
        return value
    }

    func reply(id: String, responseJSON: Data) async {
        let idData = (try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed))
            ?? Data("\"\"".utf8)
        let jsonText = String(data: responseJSON, encoding: .utf8) ?? "{}"
        let jsonStringData = try? JSONSerialization.data(withJSONObject: jsonText,
                                                         options: .fragmentsAllowed)
        let jsonString = jsonStringData.flatMap { String(data: $0, encoding: .utf8) } ?? "\"{}\""
        let idText = String(data: idData, encoding: .utf8) ?? "\"\""
        let expression =
            "window.__macsteamHubcap && window.__macsteamHubcap.reply(\(idText), JSON.parse(\(jsonString)))"
        do {
            try await evaluate(expression)
        } catch {
            HubcapLog.write("bridge: reply evaluation failed: \(error.localizedDescription)")
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        pending.values.forEach { $0.resume(throwing: CDPError.disconnected) }
        pending.removeAll()
        socket.close()
    }

    func isClosed() -> Bool { closed }

    private func connectionClosed(_ error: Error?) {
        guard !closed else { return }
        closed = true
        pending.values.forEach { $0.resume(throwing: error ?? CDPError.disconnected) }
        pending.removeAll()
    }

    // MARK: Private

    private func send(method: String, params: [String: Any] = [:]) async throws -> Data {
        guard !closed else { throw CDPError.disconnected }
        nextID += 1
        let id = nextID
        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: [
                "id": id,
                "method": method,
                "params": params,
            ])
        } catch {
            throw CDPError.badResponse(error.localizedDescription)
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            throw CDPError.badResponse("CDP command was not UTF-8")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.fail(id: id, error: CDPError.badResponse("CDP command timed out"))
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.socket.sendText(text)
                } catch {
                    await self.fail(id: id, error: error)
                }
            }
        }
    }

    private func fail(id: Int, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func handleText(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = root["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = root["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "\(error)"
                continuation.resume(throwing: CDPError.command(text))
            } else {
                let result = root["result"] as? [String: Any] ?? [:]
                let resultData = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
                continuation.resume(returning: resultData)
            }
            return
        }

        guard root["method"] as? String == "Runtime.bindingCalled",
              let params = root["params"] as? [String: Any],
              let name = params["name"] as? String,
              let payload = params["payload"] as? String else { return }
        await onBindingMessage?(name, payload)
    }
}

// MARK: - Bridge

@MainActor
final class HubcapStoreBridge {
    static let shared = HubcapStoreBridge()

    private var store: ConfigStore?
    private var installer: HubcapStoreInstaller?
    private var lockFD: Int32 = -1
    private var pages: [String: CDPPage] = [:]
    private var loopTask: Task<Void, Never>?
    private var started = false
    private var statusCache: [Int: (Date, HubcapStoreInstaller.StoreStatus)] = [:]
    private var installing = Set<Int>()
    private var lastRestart = Date.distantPast
    private let debugSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    private init() {}

    var isActive: Bool { lockFD >= 0 }

    @discardableResult
    func start(store: ConfigStore, waitForMainApp: Bool = false) -> Bool {
        guard !started else { return true }
        self.store = store
        self.installer = HubcapStoreInstaller(store: store)

        do {
            try Paths.ensureDir(Paths.configDir)
        } catch {
            HubcapLog.write("bridge: cannot create support dir: \(error.localizedDescription)")
            return false
        }

        if acquireLock() {
            beginBridge()
            return true
        }

        // A headless helper spawned by the dylib may lose the race to an open config
        // window. Wait for that window to quit instead of leaving the store button dead;
        // if the existing holder is another helper, this duplicate exits.
        if waitForMainApp && regularConfigAppRunning() {
            started = true
            HubcapLog.write("bridge: waiting for the open config app to release the bridge")
            Task { [weak self] in
                await self?.waitForLock()
            }
            return true
        }
        return false
    }

    private func acquireLock() -> Bool {
        lockFD = open(Paths.hubcapBridgeLock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else {
            HubcapLog.write("bridge: cannot open lock file")
            return false
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            lockFD = -1
            return false
        }
        return true
    }

    private func regularConfigAppRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID &&
            $0.processIdentifier != getpid() &&
            $0.activationPolicy == .regular
        }
    }

    private func waitForLock() async {
        while !Task.isCancelled {
            if !regularConfigAppRunning() {
                if acquireLock() {
                    beginBridge()
                } else {
                    HubcapLog.write("bridge: another helper holds the lock; exiting duplicate")
                    NSApp.terminate(nil)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func beginBridge() {
        if !started {
            started = true
        }
        if let executable = Bundle.main.executableURL?.path {
            try? executable.write(to: Paths.hubcapBridgePath, atomically: true, encoding: .utf8)
        }
        try? ensureDebugMarker()
        HubcapLog.write("bridge: started (\(Bundle.main.executableURL?.path ?? "unknown"))")
        loopTask = Task { [weak self] in
            await self?.run()
        }
    }

    private func ensureDebugMarker() throws {
        try Paths.ensureDir(Paths.cefDebugMarker.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: Paths.cefDebugMarker.path) {
            FileManager.default.createFile(atPath: Paths.cefDebugMarker.path, contents: Data())
        }
    }

    private func run() async {
        while !Task.isCancelled {
            await pollTabs()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func pollTabs() async {
        guard let tabs = await fetchTabs() else { return }
        var live = Set<String>()
        for tab in tabs {
            guard let id = tab.id, let urlString = tab.url,
                  let wsURLString = tab.webSocketDebuggerURL,
                  let url = URL(string: urlString),
                  let wsURL = URL(string: wsURLString),
                  url.host?.lowercased() == "store.steampowered.com" else { continue }
            live.insert(id)
            if let existing = pages[id], await existing.isClosed() {
                pages.removeValue(forKey: id)
            }
            if pages[id] == nil {
                await attach(tabID: id, wsURL: wsURL)
            }
        }
        for (id, page) in pages where !live.contains(id) {
            await page.close()
            pages.removeValue(forKey: id)
        }
    }

    private func attach(tabID: String, wsURL: URL) async {
        let page: CDPPage
        do {
            page = try CDPPage(tabID: tabID, webSocketURL: wsURL)
        } catch {
            HubcapLog.write("bridge: tab \(tabID) has an invalid URL: \(error.localizedDescription)")
            return
        }
        do {
            let script = try await Task.detached(priority: .utility) {
                try Self.storeScript()
            }.value
            try await page.start { [weak self] name, payload in
                guard name == "macsteamHubcap" else { return }
                await self?.handleBinding(payload, tabID: tabID)
            }
            // Store the page before injecting: the injected script can call the binding
            // immediately, and handleBinding must find this tab when it does.
            pages[tabID] = page
            try await page.addBinding(name: "macsteamHubcap")
            try await page.addStartupScript(script)
            try await page.evaluate(script)
            let canRefresh = try? await page.evaluateString(
                "String(typeof window.__macsteamRefresh === 'function')")
            HubcapLog.write("bridge: tab \(tabID) refresh hook: \(canRefresh ?? "nil")")
            if canRefresh == "true" {
                // The page may have sent its status request before this session attached.
                try? await page.evaluate("window.__macsteamRefresh()")
            } else {
                // An older injected script has no refresh hook; reloading gives the new
                // startup script and this session's binding a clean context.
                do {
                    try await page.reload()
                } catch {
                    HubcapLog.write("bridge: tab \(tabID) reload failed: \(error.localizedDescription)")
                }
            }
            HubcapLog.write("bridge: attached to tab \(tabID)")
        } catch {
            pages.removeValue(forKey: tabID)
            await page.close()
            HubcapLog.write("bridge: tab \(tabID) attach failed: \(error.localizedDescription)")
        }
    }

    private func fetchTabs() async -> [CDPTab]? {
        guard let url = URL(string: "http://127.0.0.1:8080/json/list") else { return nil }
        do {
            let (data, response) = try await debugSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode([CDPTab].self, from: data)
        } catch {
            return nil
        }
    }

    nonisolated private static func storeScript() throws -> String {
        var candidates: [URL] = []
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "hubcap-store", withExtension: "js") {
            candidates.append(url)
        }
        #endif
        if let url = Bundle.main.url(forResource: "hubcap-store", withExtension: "js") {
            candidates.append(url)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(
                "MacsteamApp_MacsteamApp.bundle/hubcap-store.js"))
            candidates.append(resources.appendingPathComponent("hubcap-store.js"))
        }
        for url in candidates {
            if let script = try? String(contentsOf: url, encoding: .utf8), !script.isEmpty {
                return script
            }
        }
        throw CDPError.badResponse("Hubcap store script is missing from the app.")
    }

    private func handleBinding(_ payload: String, tabID: String) async {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String,
              let appID = root["appID"] as? Int,
              let action = root["action"] as? String,
              appID > 0, appID <= 2_147_483_647 else {
            return
        }
        guard let page = pages[tabID] else { return }

        let response: [String: Any]
        switch action {
        case "status":
            response = await statusResponse(appID: appID)
        case "add":
            response = await addResponse(appID: appID)
        case "restart":
            response = ["restarting": true]
        default:
            response = ["ready": false, "error": "Unknown macSteam action."]
        }

        guard let responseData = try? JSONSerialization.data(withJSONObject: response) else { return }
        await page.reply(id: id, responseJSON: responseData)
        if action == "restart" {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        let now = Date()
        guard now.timeIntervalSince(lastRestart) > 15 else { return }
        lastRestart = now
        HubcapLog.write("bridge: restarting Steam")
        // Let the reply reach the page first, then close and relaunch Steam.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.performRestart()
        }
    }

    private func performRestart() {
        // Match process names, not full command lines: -f would also match a terminal
        // command that happens to contain these paths.
        Subprocess.run("/usr/bin/pkill", ["-9", "-x", "steam_osx"])
        Subprocess.run("/usr/bin/pkill", ["-9", "-x", "Steam"])
        Task.detached {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = Subprocess.run("/usr/bin/open", ["-a", "Steam"])
        }
    }

    private func statusResponse(appID: Int) async -> [String: Any] {
        guard let installer else { return ["error": "macSteam is still starting."] }
        if let (date, cached) = statusCache[appID],
           Date().timeIntervalSince(date) < 30 {
            return render(status: cached)
        }
        let status = await installer.status(appID: appID)
        statusCache[appID] = (Date(), status)
        return render(status: status)
    }

    private func render(status: HubcapStoreInstaller.StoreStatus) -> [String: Any] {
        switch status {
        case .ready:
            return ["ready": true]
        case .available(let gameName):
            return ["ready": false, "available": true, "name": gameName ?? ""]
        case .unavailable(let message):
            return ["ready": false, "error": message]
        }
    }

    private func addResponse(appID: Int) async -> [String: Any] {
        guard let installer else { return ["error": "macSteam is still starting."] }
        guard !installing.contains(appID) else {
            return ["ready": false, "error": "This game is already being added."]
        }
        installing.insert(appID)
        defer { installing.remove(appID) }
        do {
            let outcome = try await installer.install(appID: appID)
            statusCache[appID] = (Date(), .ready)
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.macsteam.configChanged"), object: nil)
            return [
                "ready": true,
                "activated": outcome.activated,
                "name": outcome.luaTitle ?? "",
            ]
        } catch {
            HubcapLog.write("bridge: add \(appID) failed: \(error.localizedDescription)")
            return ["ready": false, "error": error.localizedDescription]
        }
    }
}

struct CDPTab: Decodable {
    let id: String?
    let url: String?
    let title: String?
    let webSocketDebuggerURL: String?

    private enum CodingKeys: String, CodingKey {
        case id, url, title
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }
}
