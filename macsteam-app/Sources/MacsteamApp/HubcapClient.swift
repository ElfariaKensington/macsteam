import Foundation

struct HubcapGame: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let appType: String?
    let manifestAvailable: Bool
    let headerImageURL: URL?

    var appID: Int? { Int(id) }

    init(
        id: String,
        name: String,
        appType: String? = nil,
        manifestAvailable: Bool = true,
        headerImageURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.appType = appType
        self.manifestAvailable = manifestAvailable
        self.headerImageURL = headerImageURL
    }
}

struct HubcapLibraryPage: Sendable {
    let totalCount: Int
    let games: [HubcapGame]
}

private struct SteamAppDetailsEnvelope: Decodable {
    let success: Bool
    let data: SteamAppDetails?
}

private struct SteamAppDetails: Decodable {
    let name: String?
}

private struct HubcapLibraryGame: Decodable {
    let gameID: String
    let gameName: String?
    let appType: String?
    let manifestAvailable: Bool
    let headerImage: String?

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case gameName = "game_name"
        case appType = "app_type"
        case manifestAvailable = "manifest_available"
        case headerImage = "header_image"
    }

    var model: HubcapGame {
        let trimmed = gameName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HubcapGame(
            id: gameID,
            name: (trimmed?.isEmpty == false) ? trimmed! : "App \(gameID)",
            appType: appType,
            manifestAvailable: manifestAvailable,
            headerImageURL: headerImage.flatMap(URL.init(string:))
        )
    }
}

private struct HubcapLibraryResponse: Decodable {
    let status: String
    let totalCount: Int
    let limit: Int
    let offset: Int
    let search: String?
    let sortBy: String?
    let games: [HubcapLibraryGame]

    enum CodingKeys: String, CodingKey {
        case status
        case totalCount = "total_count"
        case limit
        case offset
        case search
        case sortBy = "sort_by"
        case games
    }
}

private struct HubcapSearchGame: Decodable {
    let gameID: String
    let gameName: String?
    let appType: String?
    let manifestAvailable: Bool
    let headerImage: String?

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case gameName = "game_name"
        case appType = "app_type"
        case manifestAvailable = "manifest_available"
        case headerImage = "header_image"
    }

    var model: HubcapGame {
        let trimmed = gameName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HubcapGame(
            id: gameID,
            name: (trimmed?.isEmpty == false) ? trimmed! : "App \(gameID)",
            appType: appType,
            manifestAvailable: manifestAvailable,
            headerImageURL: headerImage.flatMap(URL.init(string:))
        )
    }
}

private struct HubcapSearchResponse: Decodable {
    let status: String
    let results: [HubcapSearchGame]
}

struct HubcapUserStats: Decodable, Sendable {
    let userID: String
    let dailyUsage: Int
    let dailyLimit: Int
    let canMakeRequests: Bool
    let apiKeyExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case dailyUsage = "daily_usage"
        case dailyLimit = "daily_limit"
        case canMakeRequests = "can_make_requests"
        case apiKeyExpiresAt = "api_key_expires_at"
    }
}

enum HubcapClientError: LocalizedError {
    case invalidAPIKey
    case invalidSearch
    case unauthorized
    case rateLimited
    case unavailable
    case http(Int)
    case invalidResponse(endpoint: String, preview: String)
    case invalidLuaResponse(appID: Int, preview: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Enter a valid Hubcap API key."
        case .invalidSearch:
            return "Enter at least 3 characters to search Hubcap."
        case .unauthorized:
            return "The Hubcap API key is invalid, expired, or unauthorized."
        case .rateLimited:
            return "Hubcap's daily API limit for this key has been reached."
        case .unavailable:
            return "Hubcap doesn't have a Lua manifest for this game."
        case .http(let status):
            return "Hubcap returned HTTP \(status)."
        case .invalidResponse(let endpoint, let preview):
            return "Hubcap returned an unexpected response from \(endpoint): \(preview)"
        case .invalidLuaResponse(let appID, let preview):
            return "Hubcap returned invalid Lua for App \(appID). Response starts with: \(preview)"
        }
    }
}

final class HubcapClient: @unchecked Sendable {
    static let apiKeysURL = URL(string: "https://hubcapmanifest.com/api-keys/")!

    private let steamNameCache = NSCache<NSNumber, NSString>()
    private let session: URLSession
    private let baseURL = URL(string: "https://hubcapmanifest.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func libraryPage(apiKey: String, limit: Int = 1000, offset: Int = 0) async throws -> HubcapLibraryPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v1/library"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1000))),
            URLQueryItem(name: "offset", value: String(max(offset, 0))),
        ]

        let request = try makeRequest(
            url: components.url!,
            apiKey: apiKey,
            accept: "application/json"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decodeLibraryPage(data)
    }

    func searchGames(query: String, apiKey: String, appID: Bool = false) async throws -> [HubcapGame] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            throw HubcapClientError.invalidSearch
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v1/search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "appid", value: appID ? "true" : "false"),
        ]

        let request = try makeRequest(
            url: components.url!,
            apiKey: apiKey,
            accept: "application/json"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }

        do {
            let payload = try JSONDecoder().decode(HubcapSearchResponse.self, from: bytes)
            guard payload.status == "success" else {
                throw HubcapClientError.invalidResponse(
                    endpoint: "/api/v1/search",
                    preview: responsePreview(data)
                )
            }
            return payload.results.map(\.model)
        } catch let error as HubcapClientError {
            throw error
        } catch {
            throw HubcapClientError.invalidResponse(
                endpoint: "/api/v1/search",
                preview: responsePreview(data)
            )
        }
    }


    func userStats(apiKey: String) async throws -> HubcapUserStats {
        let request = try makeRequest(
            url: baseURL.appendingPathComponent("/api/v1/user/stats"),
            apiKey: apiKey,
            accept: "application/json"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }

        do {
            return try JSONDecoder().decode(HubcapUserStats.self, from: bytes)
        } catch {
            throw HubcapClientError.invalidResponse(
                endpoint: "/api/v1/user/stats",
                preview: responsePreview(data)
            )
        }
    }

    func steamAppName(appID: Int) async -> String? {
        let cacheKey = NSNumber(value: appID)
        if let cached = steamNameCache.object(forKey: cacheKey) {
            return cached as String
        }

        var components = URLComponents(
            url: URL(string: "https://store.steampowered.com/api/appdetails")!,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "l", value: "english"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("macSteam Hubcap Client", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode)
            else {
                return nil
            }

            let payload = try JSONDecoder().decode([String: SteamAppDetailsEnvelope].self, from: data)
            guard let details = payload[String(appID)], details.success else {
                return nil
            }

            let name = details.data?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else {
                return nil
            }

            steamNameCache.setObject(name as NSString, forKey: cacheKey)
            return name
        } catch {
            return nil
        }
    }

    func downloadLuaText(appID: Int, apiKey: String) async throws -> String {
        let request = try makeRequest(
            url: baseURL.appendingPathComponent("/api/v1/lua/\(appID)"),
            apiKey: apiKey,
            accept: "text/plain"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        guard !data.isEmpty else {
            throw HubcapClientError.unavailable
        }

        // Hubcap returns the Lua script as the response body. Decode the body directly instead of
        // round-tripping it through a temporary .lua file and Foundation's file-format detection.
        var text = String(decoding: data, as: UTF8.self)
        if text.unicodeScalars.first == "\u{FEFF}" {
            text.removeFirst()
        }

        guard LuaManifestParser.containsAddApp(text) else {
            throw HubcapClientError.invalidLuaResponse(appID: appID, preview: preview(of: text))
        }

        return text
    }

    private func preview(of text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(120))
    }

    private func makeRequest(url: URL, apiKey: String, accept: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(
            of: #"^smm_[0-9a-f]{96}$"#,
            options: .regularExpression
        ) != nil else {
            throw HubcapClientError.invalidAPIKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("macSteam Hubcap Client", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return request
    }

    private func decodeLibraryPage(_ data: Data) throws -> HubcapLibraryPage {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }

        do {
            let payload = try JSONDecoder().decode(HubcapLibraryResponse.self, from: bytes)

            guard payload.status == "success" else {
                throw HubcapClientError.invalidResponse(
                    endpoint: "/api/v1/library",
                    preview: responsePreview(data)
                )
            }

            return HubcapLibraryPage(
                totalCount: payload.totalCount,
                games: payload.games.map(\.model)
            )
        } catch let error as HubcapClientError {
            throw error
        } catch {
            throw HubcapClientError.invalidResponse(
                endpoint: "/api/v1/library",
                preview: responsePreview(data)
            )
        }
    }

    private func responsePreview(_ data: Data) -> String {
        let text = String(decoding: data.prefix(240), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "<empty body>" : text
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HubcapClientError.http(-1)
        }

        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw HubcapClientError.unauthorized
        case 404:
            throw HubcapClientError.unavailable
        case 429:
            throw HubcapClientError.rateLimited
        default:
            throw HubcapClientError.http(http.statusCode)
        }
    }
}
