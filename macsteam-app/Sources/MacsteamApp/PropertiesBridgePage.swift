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
        let payload: [Any] = [
            request.req, result.ok, result.message, result.data ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let arguments = String(data: data, encoding: .utf8) else { return }
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

@MainActor
final class SharedContextAchievementBridge {
    private var targetID: String?
    private var lastConfigStamp: Date?
    private var lastPayload: String?

    func sync(targetID: String, endpoint: URL, session: URLSession) async {
        let configURL = Paths.configFile
        let stamp = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        if self.targetID == targetID && self.lastConfigStamp == stamp && lastPayload != nil {
            return
        }

        let map = Self.loadSpoofMap(from: configURL)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: jsonData, encoding: .utf8) else { return }

        let expression = """
        (() => {
          window.__macsteamAchSpoof = \(json);
          window.__macsteamAchCache = {};
          const refreshDetails = (appid) => {
            const key = String(appid);
            if (!window.__macsteamAchSpoof || !window.__macsteamAchSpoof[key]) return;
            if (window.__macsteamAchPending && window.__macsteamAchPending[key]) return;
            window.__macsteamAchPending = window.__macsteamAchPending || {};
            window.__macsteamAchPending[key] = true;
            SteamClient.Apps.GetMyAchievementsForApp(Number(appid)).then((res) => {
              delete window.__macsteamAchPending[key];
              const list = res && res.data && Array.isArray(res.data.rgAchievements) ? res.data.rgAchievements : null;
              if (!list) return;
              const achieved = list.filter(a => a.bAchieved);
              const unachieved = list.filter(a => !a.bAchieved);
              window.__macsteamAchCache[key] = {
                vecHighlight: achieved.slice(0, 12),
                vecUnachieved: unachieved,
                vecAchievedHidden: achieved.filter(a => a.bHidden),
                nTotal: list.length,
                nAchieved: achieved.length
              };
              if (typeof appDetailsStore !== "undefined" && typeof appDetailsStore.AppDetailsChanged === "function") {
                try { appDetailsStore.AppDetailsChanged(Number(appid)); } catch {}
              }
            }).catch(() => { delete window.__macsteamAchPending[key]; });
          };
          if (!window.__macsteamAchPatched) {
            if (typeof SteamClient === "undefined" || !SteamClient.Apps || typeof SteamClient.Apps.GetMyAchievementsForApp !== "function") return "pending";
            window.__macsteamAchPatched = true;
            const orig = SteamClient.Apps.GetMyAchievementsForApp.bind(SteamClient.Apps);
            SteamClient.Apps.GetMyAchievementsForApp = async function(appid) {
              const res = await orig(appid);
              const spoof = (window.__macsteamAchSpoof || {})[String(appid)];
              if (!spoof || !res || !res.data || !Array.isArray(res.data.rgAchievements)) return res;
              const all = spoof === "all";
              const set = all ? null : new Set(spoof);
              const now = Math.floor(Date.now() / 1000);
              for (const a of res.data.rgAchievements) {
                if (all || set.has(a.strID)) {
                  a.bAchieved = true;
                  if (!a.rtUnlocked) a.rtUnlocked = now;
                }
              }
              return res;
            };
          }
          if (!window.__macsteamAchDetailsPatched && typeof appDetailsStore !== "undefined" && typeof appDetailsStore.GetAchievements === "function") {
            window.__macsteamAchDetailsPatched = true;
            const origGetAch = appDetailsStore.GetAchievements.bind(appDetailsStore);
            appDetailsStore.GetAchievements = function(appid) {
              const res = origGetAch(appid);
              const key = String(appid);
              const spoof = (window.__macsteamAchSpoof || {})[key];
              if (!spoof) return res;
              const cached = window.__macsteamAchCache && window.__macsteamAchCache[key];
              if (cached) return cached;
              refreshDetails(appid);
              return res;
            };
          }
          if (!window.__macsteamAchProgPatched && typeof appAchievementProgressCache !== "undefined" && typeof appAchievementProgressCache.GetAchievementProgress === "function") {
            window.__macsteamAchProgPatched = true;
            const origProg = appAchievementProgressCache.GetAchievementProgress.bind(appAchievementProgressCache);
            appAchievementProgressCache.GetAchievementProgress = function(appid) {
              const key = String(appid);
              const spoof = (window.__macsteamAchSpoof || {})[key];
              if (!spoof) return origProg(appid);
              if (spoof === "all") return 100;
              const cached = window.__macsteamAchCache && window.__macsteamAchCache[key];
              if (cached && cached.nTotal > 0) return Math.round((cached.nAchieved / cached.nTotal) * 100);
              refreshDetails(appid);
              return origProg(appid);
            };
          }
          for (const appid of Object.keys(window.__macsteamAchSpoof || {})) refreshDetails(appid);
          return (window.__macsteamAchDetailsPatched && window.__macsteamAchProgPatched) ? "installed" : "updated";
        })()
        """

        if await Self.evaluateStatus(expression: expression, endpoint: endpoint, session: session) == "installed" {
            self.targetID = targetID
            self.lastConfigStamp = stamp
            self.lastPayload = json
        }
    }

    static func loadSpoofMap(from configURL: URL) -> [String: Any] {
        let cfg = (try? String(contentsOf: configURL, encoding: .utf8)).map(MacsteamConfig.parse) ?? MacsteamConfig()
        var map: [String: Any] = [:]
        for (appID, sel) in cfg.achievementSpoof {
            if sel.all {
                map[String(appID)] = "all"
            } else if !sel.ids.isEmpty {
                map[String(appID)] = sel.ids
            }
        }
        return map
    }

    static func evaluateStatus(expression: String, endpoint: URL, session: URLSession) async -> String? {
        let socket = session.webSocketTask(with: endpoint)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let command: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true],
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        do {
            try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
            for _ in 0..<8 {
                let message = try await socket.receive()
                let reply: Data
                switch message {
                case .string(let text): reply = Data(text.utf8)
                case .data(let bytes): reply = bytes
                @unknown default: continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                      object["id"] as? Int == 1,
                      let outer = object["result"] as? [String: Any],
                      let remote = outer["result"] as? [String: Any],
                      let status = remote["value"] as? String else { continue }
                return status
            }
        } catch {
            // Will retry on the next poll tick if the target is still starting.
        }
        return nil
    }
}

@MainActor
final class SteamQueryCacheAchievementBridge {
    private var targetID: String?
    private var lastConfigStamp: Date?
    private var lastPayload: String?

    func sync(targetID: String, endpoint: URL, session: URLSession) async {
        let configURL = Paths.configFile
        let stamp = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        if self.targetID == targetID && self.lastConfigStamp == stamp && lastPayload != nil {
            return
        }

        let map = SharedContextAchievementBridge.loadSpoofMap(from: configURL)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: jsonData, encoding: .utf8) else { return }

        let expression = """
        (() => {
          window.__macsteamAchSpoof = \(json);
          window.__macsteamAchAdded = window.__macsteamAchAdded || {};
          const findQC = () => {
            if (window.__macsteamQC && typeof window.__macsteamQC.getQueryCache === "function") return window.__macsteamQC;
            const el = Array.from(document.querySelectorAll("*")).find(e => Object.keys(e).some(k => k.startsWith("__reactFiber") || k.startsWith("__reactContainer")));
            if (!el) return null;
            const fk = Object.keys(el).find(k => k.startsWith("__reactFiber") || k.startsWith("__reactContainer"));
            let cur = el[fk];
            while (cur && cur.return) cur = cur.return;
            const q = cur ? [cur] : [];
            const seen = new Set();
            while (q.length) {
              const n = q.shift();
              if (!n || seen.has(n)) continue;
              seen.add(n);
              if (n.memoizedProps && n.memoizedProps.client && typeof n.memoizedProps.client.getQueryCache === "function") {
                window.__macsteamQC = n.memoizedProps.client;
                return window.__macsteamQC;
              }
              if (n.child) q.push(n.child);
              if (n.sibling) q.push(n.sibling);
            }
            return null;
          };
          const qc = findQC();
          if (!qc) return "pending";

          const applyForApp = (appid) => {
            if (window.__macsteamQApplying) return;
            const numId = Number(appid);
            const strId = String(appid);
            const allQ = qc.getQueryCache().getAll();
            const schemaQ = allQ.find(x => Array.isArray(x.queryKey) && x.queryKey[0] === "achievements" && x.queryKey[1] === numId && x.queryKey[2] === "schema");
            const userQ = allQ.find(x => Array.isArray(x.queryKey) && x.queryKey[0] === "achievements" && x.queryKey[1] === numId && x.queryKey[2] === "user_achievements");
            const schema = schemaQ && schemaQ.state && schemaQ.state.data;
            const user = userQ && userQ.state && userQ.state.data;
            if (!schema || !user) return;

            const spoof = (window.__macsteamAchSpoof || {})[strId];
            const all = spoof === "all";
            const set = (!spoof || all) ? null : new Set(spoof);
            const added = window.__macsteamAchAdded[strId] || {};
            const prevAch = user.achievements || {};
            const nextAch = { ...prevAch };
            const now = Math.floor(Date.now() / 1000);
            let changed = false;

            const wantKeys = new Set();
            for (const g of schema.groups || []) {
              for (const a of g.achievements || []) {
                if (spoof && (all || set.has(a.api_name))) {
                  const k = String(a.internal_key);
                  wantKeys.add(k);
                  if (!nextAch[k] || !nextAch[k].unlocked) {
                    nextAch[k] = { internal_key: a.internal_key, unlocked: true, unlock_time: now };
                    added[k] = true;
                    changed = true;
                  }
                }
              }
            }
            for (const k of Object.keys(added)) {
              if (!wantKeys.has(k)) {
                delete nextAch[k];
                delete added[k];
                changed = true;
              }
            }
            window.__macsteamAchAdded[strId] = added;
            if (changed) {
              window.__macsteamQApplying = true;
              try { qc.setQueryData(userQ.queryKey, { ...user, achievements: nextAch }); }
              finally { window.__macsteamQApplying = false; }
            }
          };

          if (!window.__macsteamQCSubscribed) {
            window.__macsteamQCSubscribed = true;
            qc.getQueryCache().subscribe((event) => {
              if (window.__macsteamQApplying) return;
              const key = event && event.query && event.query.queryKey;
              if (!Array.isArray(key) || key[0] !== "achievements") return;
              if (key[2] !== "user_achievements" && key[2] !== "schema") return;
              const id = String(key[1]);
              if ((window.__macsteamAchSpoof && window.__macsteamAchSpoof[id]) || (window.__macsteamAchAdded && window.__macsteamAchAdded[id])) {
                applyForApp(id);
              }
            });
          }

          const ids = new Set([
            ...Object.keys(window.__macsteamAchSpoof || {}),
            ...Object.keys(window.__macsteamAchAdded || {}),
          ]);
          for (const id of ids) applyForApp(id);
          return "installed";
        })()
        """

        if await SharedContextAchievementBridge.evaluateStatus(expression: expression, endpoint: endpoint, session: session) == "installed" {
            self.targetID = targetID
            self.lastConfigStamp = stamp
            self.lastPayload = json
        }
    }
}
