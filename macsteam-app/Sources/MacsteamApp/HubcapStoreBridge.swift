import AppKit
import Foundation
import Darwin

/// CDP's runtime binding carries only app IDs and results. Hubcap credentials stay native.
@MainActor
final class HubcapStoreBridge {
    private let installer = HubcapStoreInstaller()
    private let session: URLSession
    private var pages: [String: HubcapStorePage] = [:]
    private var lockFD: Int32 = -1

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    static func registerExecutable() {
        guard let executable = Bundle.main.executableURL else { return }
        do {
            try Paths.ensureDir(Paths.configDir)
            try executable.path.write(to: Paths.configDir.appendingPathComponent("hubcap-bridge.path"),
                                      atomically: true, encoding: .utf8)
            try enableCEFDebugging(in: Paths.innerClientMacOS)
            let helper = Process()
            helper.executableURL = executable
            helper.arguments = ["--hubcap-store-bridge"]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            environment.removeValue(forKey: "STEAM_APP_BUNDLE_PATH")
            helper.environment = environment
            try helper.run()
        } catch {
            NSLog("Hubcap Store integration could not start: %@", error.localizedDescription)
        }
    }

    static func enableCEFDebugging(in clientDirectory: URL) throws {
        // Steam resolves this marker relative to the unbundled client's working
        // directory, not its Application Support data root.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: clientDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let flag = clientDirectory.appendingPathComponent(".cef-enable-remote-debugging")
        if !FileManager.default.fileExists(atPath: flag.path) {
            try Data().write(to: flag, options: .atomic)
        }
    }

    func run() async {
        do { try Paths.ensureDir(Paths.configDir) } catch { return }
        lockFD = open(Paths.configDir.appendingPathComponent("hubcap-bridge.lock").path,
                      O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { return }
        defer { close(lockFD); session.invalidateAndCancel() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return }
        var missed = 0
        while !Task.isCancelled {
            do {
                let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:8080/json/list")!)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let targets = try JSONDecoder().decode([Target].self, from: data)
                missed = 0
                let live = Set(targets.map(\.id))
                for id in pages.keys where !live.contains(id) || pages[id]?.closed == true {
                    pages.removeValue(forKey: id)?.close()
                }
                for target in targets where target.type == "page" && Self.isStoreURL(target.url) {
                    guard pages[target.id] == nil, let endpoint = target.webSocketDebuggerUrl,
                          let url = URL(string: endpoint), url.scheme == "ws", url.port == 8080,
                          ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? ""),
                          url.path.hasPrefix("/devtools/page/") else { continue }
                    let page = HubcapStorePage(socket: session.webSocketTask(with: url), installer: installer)
                    pages[target.id] = page
                    page.start()
                }
            } catch {
                missed += 1
                // Exit when Steam closes, with enough grace for its startup/relaunch. A slow
                // or restarting debug port is not a reason to quit while Steam is still running.
                if missed >= 60 {
                    if Self.steamIsRunning() { missed = 0 } else { break }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        pages.values.forEach { $0.close() }
    }

    nonisolated static func steamIsRunning() -> Bool {
        Subprocess.run("/usr/bin/pgrep", ["-x", "steam_osx"]).code == 0
    }

    static func isStoreURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host == "store.steampowered.com" && (url.port == nil || url.port == 443)
    }

    static func storeAppID(_ value: String) -> Int? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "store.steampowered.com",
              url.port == nil || url.port == 443 else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "app", let id = Int(parts[1]), id > 0, id <= Int32.max else { return nil }
        return id
    }

    /// Ask Steam through its normal IPC API so activation runs on its pipe-owning
    /// thread, without navigating or refreshing the Store document.
    static func querySubscription(_ appID: Int) async throws {
        guard appID > 0, appID <= Int32.max else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:8080/json/list")!)
        let targets = try JSONDecoder().decode([Target].self, from: data)
        guard let target = targets.first(where: {
            guard let url = URL(string: $0.url) else { return false }
            return $0.type == "page" && url.scheme == "https" && url.host == "steamloopback.host"
                && url.path == "/index.html"
        }), let endpoint = target.webSocketDebuggerUrl, let url = URL(string: endpoint),
            url.scheme == "ws", url.host == "127.0.0.1", url.port == 8080,
            url.path.hasPrefix("/devtools/page/") else { throw URLError(.cannotConnectToHost) }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
        let command: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": [
            "expression": "SteamClient.Apps.GetIsSubscribedApp(\(appID))", "awaitPromise": true,
            "returnByValue": true]]
        let encoded = try JSONSerialization.data(withJSONObject: command)
        try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
        _ = try await socket.receive()
    }

    private struct Target: Decodable {
        let id: String
        let type: String
        let url: String
        let webSocketDebuggerUrl: String?
    }
}

@MainActor
private final class HubcapStorePage {
    private let socket: URLSessionWebSocketTask
    private let installer: HubcapStoreInstaller
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    private var contexts: [Int: String] = [:]
    private var topFrame = ""
    private var reader: Task<Void, Never>?
    private(set) var closed = false

    init(socket: URLSessionWebSocketTask, installer: HubcapStoreInstaller) {
        self.socket = socket
        self.installer = installer
    }

    func start() {
        socket.resume()
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    received(object)
                }
            } catch { close() }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await call("Page.enable")
                let tree = try await call("Page.getFrameTree")
                topFrame = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String ?? ""
                _ = try await call("Runtime.enable")
                _ = try await call("Runtime.addBinding", ["name": "macsteamHubcap"])
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("MacsteamApp_MacsteamApp.bundle/hubcap-store.js")
                var file = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    ?? Bundle.main.url(forResource: "hubcap-store", withExtension: "js")
                #if SWIFT_PACKAGE
                if file == nil { file = Bundle.module.url(forResource: "hubcap-store", withExtension: "js") }
                #endif
                guard let file else { throw HubcapStoreError(message: "Hubcap Store script is missing from the app.") }
                let source = try String(contentsOf: file, encoding: .utf8)
                _ = try await call("Page.addScriptToEvaluateOnNewDocument", ["source": source])
                let result = try await call("Runtime.evaluate", ["expression": source])
                if result["exceptionDetails"] != nil {
                    throw HubcapStoreError(message: "Steam rejected the Hubcap Store script.")
                }
            } catch {
                NSLog("Hubcap Store page could not attach: %@", error.localizedDescription)
                close()
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .goingAway, reason: nil)
        reader?.cancel()
        let pending = waiting
        waiting.removeAll()
        pending.values.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }

    private func call(_ method: String, _ parameters: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed else { throw URLError(.networkConnectionLost) }
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": parameters])
        let text = String(decoding: data, as: UTF8.self)
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            Task {
                do { try await socket.send(.string(text)) }
                catch { waiting.removeValue(forKey: id)?.resume(throwing: error) }
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                waiting.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut))
            }
        }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
    }

    private func received(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                waiting.removeValue(forKey: id)?.resume(throwing: HubcapStoreError(
                    message: error["message"] as? String ?? "Steam browser rejected the request."))
            } else {
                let data = (try? JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
                waiting.removeValue(forKey: id)?.resume(returning: data)
            }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "Page.frameNavigated":
            if let frame = params["frame"] as? [String: Any], frame["parentId"] == nil {
                topFrame = frame["id"] as? String ?? ""
            }
        case "Runtime.executionContextCreated":
            if let context = params["context"] as? [String: Any], let id = context["id"] as? Int,
               context["origin"] as? String == "https://store.steampowered.com",
               let aux = context["auxData"] as? [String: Any], aux["isDefault"] as? Bool == true {
                contexts[id] = aux["frameId"] as? String
            }
        case "Runtime.executionContextDestroyed":
            if let id = params["executionContextId"] as? Int { contexts.removeValue(forKey: id) }
        case "Runtime.executionContextsCleared": contexts.removeAll()
        case "Runtime.bindingCalled":
            guard params["name"] as? String == "macsteamHubcap",
                  let context = params["executionContextId"] as? Int, !topFrame.isEmpty,
                  contexts[context] == topFrame, let text = params["payload"] as? String,
                  text.utf8.count <= 1024, let data = text.data(using: .utf8),
                  let request = try? JSONDecoder().decode(Request.self, from: data),
                  request.appID > 0, request.appID <= Int32.max, request.id.count <= 80,
                  ["status", "add"].contains(request.action) else { return }
            Task { await handle(request, context: context) }
        default: break
        }
    }

    private func handle(_ request: Request, context: Int) async {
        var response: [String: Any]
        do {
            // Revalidate the live top frame, including AppID, before any mutation.
            let location = try await call("Runtime.evaluate", ["expression": "location.href", "contextId": context])
            let value = (location["result"] as? [String: Any])?["value"] as? String ?? ""
            guard HubcapStoreBridge.storeAppID(value) == request.appID, contexts[context] == topFrame else { return }
            if request.action == "add" { try await installer.install(appID: request.appID) }
            response = installer.status(appID: request.appID)
        } catch { response = ["error": error.localizedDescription] }
        guard let data = try? JSONSerialization.data(withJSONObject: [request.id, response]) else { return }
        let arguments = String(decoding: data, as: UTF8.self)
        _ = try? await call("Runtime.evaluate", ["contextId": context,
            "expression": "window.__macsteamHubcap?.reply(...\(arguments))"])
    }

    private struct Request: Decodable {
        let id: String
        let appID: Int
        let action: String
    }
}
