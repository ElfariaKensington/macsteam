// CDP bridge for the achievements tab in Steam's game-properties window.
import AppKit
import Foundation

struct PropertiesAchievementRequest: Decodable {
    let req: String
    let action: String
    let title: String?
    let appid: Int?
    let ids: [String]?
    let upload: Bool?
}

@MainActor
final class PropertiesBridgePage {
    private let socket: URLSessionWebSocketTask
    private let handler = PropertiesAchievementHandler()
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    private var reader: Task<Void, Never>?
    private(set) var closed = false

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
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
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    received(object)
                }
            } catch {
                close()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await call("Page.enable")
                _ = try await call("Runtime.enable")
                _ = try await call("Runtime.addBinding", ["name": "macsteamAchievements"])
                guard let file = Self.bundledScript() else { throw URLError(.fileDoesNotExist) }
                let source = try String(contentsOf: file, encoding: .utf8)
                let reset = """
                try {
                  if (typeof window.__macsteamPropertiesTeardown === 'function') {
                    window.__macsteamPropertiesTeardown();
                  }
                } catch (e) {}
                try {
                  document.getElementById('macsteam-properties-layer')?.remove();
                  document.getElementById('macsteam-properties-picker')?.remove();
                  document.querySelectorAll('#macsteam-properties-pane').forEach(function (el) { el.remove(); });
                  document.querySelectorAll('[data-macsteam-dimmed]').forEach(function (el) { el.removeAttribute('data-macsteam-dimmed'); });
                  delete window.__macsteamPropertiesInstalled;
                } catch (e) {}
                """
                _ = try await call("Runtime.evaluate", ["expression": reset])
                _ = try await call("Page.addScriptToEvaluateOnNewDocument", ["source": source])
                let result = try await call("Runtime.evaluate", ["expression": source])
                if result["exceptionDetails"] != nil {
                    throw URLError(.badServerResponse)
                }
            } catch {
                NSLog("macSteam properties tab could not attach: %@", error.localizedDescription)
                close()
            }
        }
    }

    private static func bundledScript() -> URL? {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("MacsteamApp_MacsteamApp.bundle/properties.js")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        if let file = Bundle.main.url(forResource: "properties", withExtension: "js") { return file }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "properties", withExtension: "js")
        #else
        return nil
        #endif
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
                try? await Task.sleep(for: .seconds(8))
                waiting.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut))
            }
        }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
    }

    private func received(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                waiting.removeValue(forKey: id)?.resume(throwing: URLError(
                    .cannotParseResponse,
                    userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Steam rejected the request."]))
            } else {
                let data = (try? JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:]))
                    ?? Data("{}".utf8)
                waiting.removeValue(forKey: id)?.resume(returning: data)
            }
            return
        }

        let params = message["params"] as? [String: Any] ?? [:]
        guard message["method"] as? String == "Runtime.bindingCalled",
              params["name"] as? String == "macsteamAchievements",
              let payload = params["payload"] as? String,
              payload.utf8.count <= 512 * 1024,
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(PropertiesAchievementRequest.self, from: data),
              request.req.count <= 80,
              (request.ids?.count ?? 0) <= 2000,
              (request.ids ?? []).allSatisfy({ $0.count <= 120 }),
              (request.title?.count ?? 0) <= 120 else { return }

        Task { await respond(to: request) }
    }

    private func respond(to request: PropertiesAchievementRequest) async {
        let result = await handler.handle(request)
        guard let data = try? JSONSerialization.data(withJSONObject: [
            request.req, result.ok, result.message, result.data ?? NSNull()
        ]), let arguments = String(data: data, encoding: .utf8) else { return }
        _ = try? await call("Runtime.evaluate", [
            "expression": "window.macsteamAchievementResult(...\(arguments))"
        ])
    }

}

@MainActor
final class PropertiesAchievementHandler {
    private let store = ConfigStore()
    private let schemaFetcher = AchievementSchemaFetcher()

    struct Result {
        let ok: Bool
        let message: String
        let data: [String: Any]?
    }

    func handle(_ request: PropertiesAchievementRequest) async -> Result {
        switch request.action {
        case "list":
            guard let title = request.title, !title.isEmpty else {
                return Result(ok: false, message: "Could not read the game name.", data: nil)
            }
            guard let appID = resolveAppID(title) else {
                return Result(ok: false, message: "Could not match this game to a Steam AppID.", data: nil)
            }
            store.load()
            var definitions: [AchievementDefinition]
            do {
                definitions = try AchievementCatalog.load(appID: appID)
            } catch {
                if await schemaFetcher.ensureSchema(appID: appID),
                   let loaded = try? AchievementCatalog.load(appID: appID) {
                    definitions = loaded
                } else {
                    return Result(ok: false, message: error.localizedDescription, data: nil)
                }
            }

            let selection = store.config.achievementSelection(for: appID)
            let selected: Set<String>
            if selection?.all == true {
                selected = Set(definitions.map(\.id))
            } else {
                selected = Set(selection?.ids ?? [])
            }
            let rows: [[String: Any]] = definitions.map { definition in
                [
                    "id": definition.id,
                    "name": definition.name,
                    "description": definition.detail,
                    "hidden": definition.hidden,
                    "selected": selected.contains(definition.id),
                ]
            }
            return Result(ok: true, message: "", data: ["appid": appID, "achievements": rows])

        case "upload":
            guard let title = request.title, !title.isEmpty,
                  let appID = resolveAppID(title) else {
                return Result(ok: false, message: "Could not match this game to a Steam AppID.", data: nil)
            }
            store.load()
            var definitions: [AchievementDefinition]
            do {
                definitions = try AchievementCatalog.load(appID: appID)
            } catch {
                if await schemaFetcher.ensureSchema(appID: appID),
                   let loaded = try? AchievementCatalog.load(appID: appID) {
                    definitions = loaded
                } else {
                    return Result(ok: false, message: error.localizedDescription, data: nil)
                }
            }
            let selection = store.config.achievementSelection(for: appID)
            let ids: [String]
            if selection?.all == true {
                ids = definitions.map(\.id)
            } else {
                ids = selection?.ids ?? []
            }
            guard !ids.isEmpty else {
                return Result(ok: false,
                              message: "No achievements are selected. Use Manage Achievements first.",
                              data: nil)
            }
            let upload = await SteamAchievementUploader.upload(appID: appID, ids: ids)
            return Result(ok: upload.ok, message: upload.message, data: nil)

        case "clear":
            guard let title = request.title, !title.isEmpty,
                  let appID = resolveAppID(title) else {
                return Result(ok: false, message: "Could not match this game to a Steam AppID.", data: nil)
            }
            store.load()
            do {
                try store.setAchievementAll(appID, enabled: false)
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(rawValue: "com.macsteam.achievements.refresh" as CFString),
                    nil, nil, true)
                return Result(ok: true,
                              message: "Selection cleared. Restart Steam to restore the original values.",
                              data: nil)
            } catch {
                return Result(ok: false, message: error.localizedDescription, data: nil)
            }

        case "save":
            guard let appID = request.appid, appID > 0, appID <= 0xffffff else {
                return Result(ok: false, message: "Invalid AppID.", data: nil)
            }
            guard let ids = request.ids else {
                return Result(ok: false, message: "No achievement selection was sent.", data: nil)
            }
            store.load()
            let definitions = (try? AchievementCatalog.load(appID: appID)) ?? []
            let known = Set(definitions.map(\.id))
            let chosen = definitions.isEmpty
                ? Array(Set(ids)).sorted()
                : Array(Set(ids).intersection(known)).sorted()

            do {
                if chosen.isEmpty {
                    try store.setAchievementAll(appID, enabled: false)
                } else if chosen.count == definitions.count && !definitions.isEmpty {
                    try store.setAchievementAll(appID, enabled: true)
                } else {
                    try store.setAchievementIDs(appID, ids: chosen)
                }
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(rawValue: "com.macsteam.achievements.refresh" as CFString),
                    nil, nil, true)

                var message: String
                if chosen.isEmpty {
                    message = "Achievement spoofing cleared. Restart Steam to restore the original values."
                } else {
                    message = "Saved \(chosen.count) achievement\(chosen.count == 1 ? "" : "s"). "
                        + "Restart Steam to apply."
                }

                if request.upload == true && !chosen.isEmpty {
                    let upload = await SteamAchievementUploader.upload(appID: appID, ids: chosen)
                    message = upload.message
                    return Result(ok: upload.ok, message: message, data: nil)
                }
                return Result(ok: true, message: message, data: nil)
            } catch {
                return Result(ok: false, message: error.localizedDescription, data: nil)
            }

        default:
            return Result(ok: false, message: "Unknown achievement action.", data: nil)
        }
    }

    private func resolveAppID(_ title: String) -> Int? {
        store.load()
        if let match = store.config.appNames.first(where: {
            $0.value.caseInsensitiveCompare(title) == .orderedSame
        }) {
            return match.key
        }
        return SteamLibrary.appID(named: title)
    }
}
