// Hubcap catalog client. Everything here talks to hubcapmanifest.com directly with
// the user's own API key; no lua.tools proxy is involved.
import Foundation

// MARK: - Credential storage

enum HubcapCredentialStore {
    static let defaultsKey = "hubcap.apiKey"

    private static let keyPattern = try! NSRegularExpression(pattern: #"^smm_[0-9a-f]{96}$"#)

    static func isValidFormat(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = key as NSString
        return keyPattern.firstMatch(in: key, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static var apiKey: String? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func save(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFormat(key) else { throw HubcapClientError.invalidKeyFormat }
        UserDefaults.standard.set(key, forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

// MARK: - Models

struct HubcapUserStats: Decodable, Sendable {
    let username: String?
    let dailyUsage: Int?
    let dailyLimit: Int?
    let canMakeRequests: Bool?
    let apiKeyExpiresAt: String?
    let roleDailyLimit: Int?

    private enum CodingKeys: String, CodingKey {
        case username
        case dailyUsage = "daily_usage"
        case dailyLimit = "daily_limit"
        case canMakeRequests = "can_make_requests"
        case apiKeyExpiresAt = "api_key_expires_at"
        case roleDailyLimit = "role_daily_limit"
    }

    var summary: String {
        let used = dailyUsage ?? 0
        let limit = dailyLimit ?? roleDailyLimit
        if let limit {
            return "\(used) of \(limit) downloads used today"
        }
        return "Connected"
    }
}

struct HubcapManifestStatus: Decodable, Sendable {
    let appID: Int
    let gameName: String?
    let status: String?
    let manifestFileExists: Bool?
    let needsUpdate: Bool?
    let fileSize: Int64?

    var isAvailable: Bool {
        manifestFileExists == true || status?.lowercased() == "available"
    }

    private enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case gameName = "game_name"
        case status
        case manifestFileExists = "manifest_file_exists"
        case needsUpdate = "needs_update"
        case fileSize = "file_size"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeFlexibleInt(forKey: .appID) ?? 0
        gameName = try c.decodeIfPresent(String.self, forKey: .gameName)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        manifestFileExists = try c.decodeIfPresent(Bool.self, forKey: .manifestFileExists)
        needsUpdate = try c.decodeIfPresent(Bool.self, forKey: .needsUpdate)
        fileSize = try c.decodeFlexibleInt64(forKey: .fileSize)
    }
}

struct HubcapGame: Identifiable, Hashable, Decodable, Sendable {
    let gameID: Int
    let gameName: String
    let headerImage: String?
    let uploadedDate: String?
    let manifestAvailable: Bool?

    var id: Int { gameID }
    var appID: Int? { gameID > 0 ? gameID : nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameID = try c.decodeFlexibleInt(forKey: .gameID) ?? 0
        gameName = try c.decodeIfPresent(String.self, forKey: .gameName) ?? ""
        headerImage = try c.decodeIfPresent(String.self, forKey: .headerImage)
        uploadedDate = try c.decodeIfPresent(String.self, forKey: .uploadedDate)
        manifestAvailable = try c.decodeIfPresent(Bool.self, forKey: .manifestAvailable)
    }

    private enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case gameName = "game_name"
        case headerImage = "header_image"
        case uploadedDate = "uploaded_date"
        case manifestAvailable = "manifest_available"
    }
}

struct HubcapLibraryPage: Sendable {
    let totalCount: Int?
    let games: [HubcapGame]
}

struct HubcapSearchResponse: Sendable {
    let totalMatches: Int?
    let results: [HubcapGame]
}

enum HubcapClientError: LocalizedError, Sendable {
    case invalidKeyFormat
    case invalidKey
    case limitReached
    case noManifest
    case network(String)
    case http(Int, String)
    case invalidResponse
    case invalidLuaResponse
    case invalidManifestArchive

    var errorDescription: String? {
        switch self {
        case .invalidKeyFormat:
            return "Enter a valid Hubcap API key."
        case .invalidKey:
            return "The Hubcap API key is invalid, expired, or unauthorized."
        case .limitReached:
            return "Hubcap's daily API limit for this key has been reached."
        case .noManifest:
            return "Hubcap doesn't have a Lua manifest for this game."
        case .network(let detail):
            return "Couldn't reach Hubcap: \(detail)"
        case .http(let code, let detail):
            return detail.isEmpty ? "Hubcap returned HTTP \(code)." : detail
        case .invalidResponse:
            return "Hubcap returned an unexpected response."
        case .invalidLuaResponse:
            return "Hubcap returned invalid Lua."
        case .invalidManifestArchive:
            return "Hubcap's manifest ZIP is damaged."
        }
    }
}

// MARK: - Client

actor HubcapClient {
    static let shared = HubcapClient()

    static let defaultBaseURL = URL(string: "https://hubcapmanifest.com")!
    static let apiKeysURL = URL(string: "https://hubcapmanifest.com/api-keys/")!
    static let maximumArchiveBytes: Int64 = 256 * 1024 * 1024

    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? Self.defaultBaseURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "macSteam Config/0.9"]
        session = URLSession(configuration: cfg)
    }

    // MARK: Key validation

    func userStats(apiKey: String) async throws -> HubcapUserStats {
        let url = try makeURL(path: "/api/v1/user/stats", query: ["api_key": apiKey])
        let data = try await get(url, accept: "application/json")
        return try decode(HubcapUserStats.self, from: data)
    }

    func validate(apiKey: String) async throws -> HubcapUserStats {
        guard HubcapCredentialStore.isValidFormat(apiKey) else { throw HubcapClientError.invalidKeyFormat }
        let stats = try await userStats(apiKey: apiKey)
        guard stats.canMakeRequests != false else { throw HubcapClientError.limitReached }
        return stats
    }

    // MARK: Catalog

    func manifestStatus(appID: Int, apiKey: String) async throws -> HubcapManifestStatus? {
        let url = try makeURL(path: "/api/v1/status/\(appID)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw HubcapClientError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(status: http.statusCode, data: data)
        }
        return try decode(HubcapManifestStatus.self, from: data)
    }

    func libraryPage(apiKey: String, limit: Int = 100, offset: Int = 0) async throws -> HubcapLibraryPage {
        let url = try makeURL(path: "/api/v1/library", query: [
            "limit": String(max(1, min(limit, 100))),
            "offset": String(max(0, offset)),
            "api_key": apiKey,
        ])
        let data = try await get(url, accept: "application/json")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubcapClientError.invalidResponse
        }
        let games = try decodeGames(root["games"])
        return HubcapLibraryPage(totalCount: flexibleInt(root["total_count"]), games: games)
    }

    func searchGames(query: String, apiKey: String) async throws -> HubcapSearchResponse {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else {
            throw HubcapClientError.http(400, "Enter at least 3 characters to search Hubcap.")
        }
        let url = try makeURL(path: "/api/v1/search", query: ["q": q, "api_key": apiKey])
        let data = try await get(url, accept: "application/json")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubcapClientError.invalidResponse
        }
        let games = try decodeGames(root["results"])
        return HubcapSearchResponse(totalMatches: flexibleInt(root["total_matches"]), results: games)
    }

    // MARK: Downloads

    func downloadLuaText(appID: Int, apiKey: String) async throws -> String {
        let url = try makeURL(path: "/api/v1/lua/\(appID)", query: ["api_key": apiKey])
        let data = try await get(url, accept: "text/plain")
        guard let text = String(data: data, encoding: .utf8),
              text.contains("addappid") else {
            throw HubcapClientError.invalidLuaResponse
        }
        return text
    }

    func downloadManifestArchive(appID: Int, apiKey: String) async throws -> Data {
        let url = try makeURL(path: "/api/v1/manifest/\(appID)", query: ["api_key": apiKey])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw HubcapClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(status: http.statusCode, data: data)
        }
        guard Int64(data.count) <= Self.maximumArchiveBytes else {
            throw HubcapClientError.http(413, "Hubcap's manifest ZIP is too large.")
        }
        guard data.count > 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B else {
            throw HubcapClientError.invalidManifestArchive
        }
        return data
    }

    // MARK: Plumbing

    private func makeURL(path: String, query: [String: String] = [:]) throws -> URL {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw HubcapClientError.invalidResponse
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw HubcapClientError.invalidResponse }
        return url
    }

    private func get(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw HubcapClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(status: http.statusCode, data: data)
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw HubcapClientError.network(error.localizedDescription)
        }
    }

    private func mapHTTPError(status: Int, data: Data) -> HubcapClientError {
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0?["detail"] as? String } ?? ""
        switch status {
        case 401, 403:
            return .invalidKey
        case 429:
            return .limitReached
        case 404:
            return .noManifest
        case 400 where !detail.isEmpty:
            return .http(status, detail)
        default:
            return .http(status, detail)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HubcapClientError.invalidResponse
        }
    }

    private func decodeGames(_ raw: Any?) throws -> [HubcapGame] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let array = raw as? [[String: Any]] else { throw HubcapClientError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: array)
        do {
            return try JSONDecoder().decode([HubcapGame].self, from: data)
        } catch {
            throw HubcapClientError.invalidResponse
        }
    }

    private func flexibleInt(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - Lenient integer decoding

extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) throws -> Int? {
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return n }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    func decodeFlexibleInt64(forKey key: Key) throws -> Int64? {
        if let n = try? decodeIfPresent(Int64.self, forKey: key) { return n }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }
}
