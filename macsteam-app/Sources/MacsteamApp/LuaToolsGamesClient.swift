// LuaTools game add flow: Steam search, source availability check, and authenticated
// manifest ZIP download (Lua + depot manifests). Installation is handled by
// LuaToolsManifestInstaller so this class only talks network.
import Foundation

struct LuaToolsSteamGame: Identifiable, Sendable, Hashable {
    let id: Int
    let name: String
    let image: String?
}

struct LuaToolsUsage: Sendable, Equatable {
    let used: Int
    let limit: Int

    var remaining: Int { max(0, limit - used) }
}

enum LuaToolsGamesError: LocalizedError {
    case invalidResponse
    case network(String)
    case http(Int, String)
    case noSources
    case dailyLimit
    case downloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "lua.tools returned an unexpected response."
        case .network(let detail):
            return "Couldn't reach lua.tools: \(detail)"
        case .http(let code, let detail):
            return detail.isEmpty ? "lua.tools returned HTTP \(code)." : detail
        case .noSources:
            return "No LuaTools manifest source is available for this game."
        case .dailyLimit:
            return "Your lua.tools daily download limit has been reached."
        case .downloadTooLarge:
            return "The downloaded manifest ZIP is too large."
        }
    }
}

actor LuaToolsGamesClient {
    static let shared = LuaToolsGamesClient()

    private let session: URLSession
    private let sourceChecker = URL(string: "http://167.235.229.108/check_apis")!
    private let apiBase = URL(string: "https://lua.tools")!

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "macSteam Config/0.9"]
        session = URLSession(configuration: cfg)
    }

    // MARK: - Steam search

    func search(_ rawQuery: String) async throws -> [LuaToolsSteamGame] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var comps = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "l", value: "english"),
            URLQueryItem(name: "cc", value: "US"),
        ]
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: comps.url!)
        } catch {
            throw LuaToolsGamesError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LuaToolsGamesError.invalidResponse
        }
        struct SearchResponse: Decodable {
            let items: [Item]?
            struct Item: Decodable {
                let type: String?
                let name: String?
                let id: Int?
                let tiny_image: String?
            }
        }
        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw LuaToolsGamesError.invalidResponse
        }
        var out: [LuaToolsSteamGame] = []
        var seen = Set<Int>()
        for item in decoded.items ?? [] {
            guard item.type == nil || item.type == "app",
                  let id = item.id, id > 0,
                  let name = item.name, !name.isEmpty,
                  seen.insert(id).inserted else { continue }
            out.append(LuaToolsSteamGame(id: id, name: name, image: item.tiny_image))
        }
        if let appID = Int(query), !out.contains(where: { $0.id == appID }) {
            let infoMap = await SteamStoreClient.shared.resolve(appIDs: [appID])
            if let info = infoMap[appID] {
                out.insert(LuaToolsSteamGame(id: appID, name: info.name,
                                             image: info.headerURL), at: 0)
            }
        }
        return Array(out.prefix(30))
    }

    // MARK: - Source availability

    func sources(appID: Int) async throws -> [String] {
        var comps = URLComponents(url: sourceChecker, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "appid", value: String(appID))]
        var request = URLRequest(url: comps.url!)
        request.setValue("secretgoonpoon", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LuaToolsGamesError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LuaToolsGamesError.invalidResponse
        }
        guard let statuses = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw LuaToolsGamesError.invalidResponse
        }
        let available = statuses.filter { $0.value.lowercased() == "available" }
            .keys.sorted()
        guard !available.isEmpty else { throw LuaToolsGamesError.noSources }
        return available
    }

    // MARK: - Daily usage

    /// Standard lua.tools limit: 25 downloads per UTC day, read from the same
    /// Supabase `user_downloads` rows the website counts. RLS scopes the query to
    /// the signed-in user.
    func usage() async -> LuaToolsUsage? {
        guard await LuaToolsAuth.shared.isSignedIn() else { return nil }
        guard let token = try? await LuaToolsAuth.shared.accessToken() else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'00:00:00'Z'"
        let today = formatter.string(from: Date())

        var comps = URLComponents(
            url: URL(string: "https://db.lua.tools/rest/v1/user_downloads")!,
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "appid"),
            URLQueryItem(name: "downloaded_at", value: "gte.\(today)"),
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "HEAD"
        request.setValue(LuaToolsAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            guard let used = Self.usageCount(
                fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
            else { return nil }
            return LuaToolsUsage(used: used, limit: 25)
        } catch {
            return nil
        }
    }

    static func usageCount(fromContentRange range: String?) -> Int? {
        guard let range, let count = range.split(separator: "/").last else { return nil }
        return Int(count)
    }

    // MARK: - Manifest download

    func downloadManifest(appID: Int, source: String, gameName: String) async throws -> Data {
        var comps = URLComponents(url: apiBase.appendingPathComponent("/api/manifest/download"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "appid", value: String(appID)),
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "game_name", value: gameName),
        ]
        let data = try await authenticatedDownload(url: comps.url!, token: nil)
        guard data.count <= 256 * 1024 * 1024 else {
            throw LuaToolsGamesError.downloadTooLarge
        }
        LuaToolsLog.write("Downloaded LuaTools manifest ZIP for app \(appID) "
                          + "from \(source) (\(data.count) bytes).")
        return data
    }

    private func authenticatedDownload(url: URL, token: String?) async throws -> Data {
        let jwt: String
        if let token {
            jwt = token
        } else {
            jwt = try await LuaToolsAuth.shared.accessToken()
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LuaToolsGamesError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LuaToolsGamesError.invalidResponse
        }
        if http.statusCode == 401, token == nil {
            let refreshed = try await LuaToolsAuth.shared.accessToken(forceRefresh: true)
            return try await authenticatedDownload(url: url, token: refreshed)
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error"] as? String ?? $0?["msg"] as? String } ?? ""
            if http.statusCode == 429
                || (http.statusCode == 403 && detail.lowercased().contains("limit")) {
                throw LuaToolsGamesError.dailyLimit
            }
            throw LuaToolsGamesError.http(http.statusCode, detail)
        }
        return data
    }
}
