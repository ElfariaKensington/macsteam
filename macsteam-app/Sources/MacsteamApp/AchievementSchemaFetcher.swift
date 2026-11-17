// Fetches a missing achievement schema through the Steam client's own
// GetFriendAchievementsForApp API, using a public reviewer as the source.
import Foundation

@MainActor
final class AchievementSchemaFetcher {
    private let session: URLSession
    private let steamIDBase: UInt64 = 76561197960265728

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    func ensureSchema(appID: Int) async -> Bool {
        if schemaIsReady(appID: appID) { return true }
        // If the store says the game has no achievements, no schema will ever
        // appear. Fail before the reviewer lookup and its network timeouts.
        if await storeHasAchievements(appID: appID) == false { return false }

        let reviewers = await reviewerSteamIDs(appID: appID)
        for reviewer in reviewers.prefix(8) {
            _ = await requestFriendAchievements(appID: appID, steamID: reviewer)
            for _ in 0..<12 {
                if schemaIsReady(appID: appID) { return true }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return schemaIsReady(appID: appID)
    }

    /// The store metadata is the fastest way to distinguish "no achievement
    /// schema yet" from "this game has no achievements". nil means unknown.
    func storeHasAchievements(appID: Int) async -> Bool? {
        guard let url = URL(string:
            "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english") else {
            return nil
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appID)] as? [String: Any],
              entry["success"] as? Bool == true,
              let details = entry["data"] as? [String: Any] else {
            return nil
        }
        if let achievements = details["achievements"] as? [String: Any],
           let total = achievements["total"] as? Int {
            return total > 0
        }
        if let categories = details["categories"] as? [[String: Any]] {
            return categories.contains {
                (($0["description"] as? String) ?? "").localizedCaseInsensitiveContains("achievement")
            }
        }
        return false
    }

    private func schemaIsReady(appID: Int) -> Bool {
        let path = AchievementCatalog.schemaURL(appID: appID).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return false }
        return size > 64
    }

    private func reviewerSteamIDs(appID: Int) async -> [String] {
        guard let url = URL(string:
            "https://steamcommunity.com/app/\(appID)/reviews/?browsefilter=mostrecent&p=1") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        var ids: [String] = []
        let patterns = [
            #"steamcommunity\.com/profiles/(\d{15,20})"#,
            #"data-miniprofile="(\d{1,10})""#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let capture = Range(match.range(at: 1), in: html) else { continue }
                let text = String(html[capture])
                let steamID: String
                if index == 0 {
                    steamID = text
                } else if let account = UInt64(text), account > 0, account <= 0xFFFFFFFF {
                    steamID = String(steamIDBase + account)
                } else {
                    continue
                }
                if !ids.contains(steamID) { ids.append(steamID) }
                if ids.count >= 8 { break }
            }
            if ids.count >= 8 { break }
        }
        return ids
    }

    private func requestFriendAchievements(appID: Int, steamID: String) async -> Bool {
        let expression = "SteamClient.Apps.GetFriendAchievementsForApp(\"\(appID)\",\"\(steamID)\")" +
            ".then(r=>JSON.stringify({result:r.result})).catch(e=>JSON.stringify({result:-1}))"
        guard let value = await Self.evaluateInSharedContext(expression, session: session) else {
            return false
        }
        return value.contains("\"result\":1")
    }

    static func evaluateInSharedContext(_ expression: String,
                                        session: URLSession? = nil) async -> String? {
        let session = session ?? URLSession(configuration: .ephemeral)
        guard let listURL = URL(string: "http://127.0.0.1:8080/json/list"),
              let (data, _) = try? await session.data(from: listURL),
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let target = targets.first(where: { ($0["title"] as? String) == "SharedJSContext" }),
              let endpoint = target["webSocketDebuggerUrl"] as? String,
              let url = URL(string: endpoint) else {
            return nil
        }

        let socket = session.webSocketTask(with: url)
        socket.resume()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let command: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true, "returnByValue": true],
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        do {
            try await socket.send(.string(String(decoding: encoded, as: UTF8.self)))
            for _ in 0..<12 {
                let message = try await socket.receive()
                let reply: Data
                switch message {
                case .string(let text): reply = Data(text.utf8)
                case .data(let bytes): reply = bytes
                @unknown default: continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                    continue
                }
                guard object["id"] as? Int == 1 else { continue }
                if object["error"] is [String: Any] {
                    return nil
                }
                guard let outer = object["result"] as? [String: Any] else { return nil }
                if outer["exceptionDetails"] != nil {
                    return nil
                }
                guard let remote = outer["result"] as? [String: Any] else { return nil }
                return remote["value"] as? String
            }
        } catch {
            return nil
        }
        return nil
    }

}
