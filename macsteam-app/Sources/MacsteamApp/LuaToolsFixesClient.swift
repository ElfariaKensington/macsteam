// LuaTools "Fixes" catalog (Denuvo fixes). Listings and per-game fix details are
// public; downloading a fix or its manifest requires a lua.tools/Discord session,
// so macSteam opens the matching lua.tools page for that part.
import Foundation

struct LuaToolsFixTag: Decodable, Sendable, Hashable {
    let id: String
    let name: String
    let slug: String?
    let color: String?
}

struct LuaToolsFixGame: Decodable, Sendable, Identifiable {
    let appID: String
    let name: String
    let headerImage: String?
    let fixCount: Int
    let tags: [LuaToolsFixTag]

    var id: String { appID }
    var numericAppID: Int? { Int(appID) }

    private enum CodingKeys: String, CodingKey {
        case appID = "appid"
        case name
        case headerImage = "header_image"
        case fixCount
        case tags
    }
}

struct LuaToolsFixListings: Decodable, Sendable {
    let games: [LuaToolsFixGame]
    let tags: [LuaToolsFixTag]
}

struct LuaToolsFixDetail: Decodable, Sendable {
    let appID: String
    let name: String
    let headerImage: String?
    let fixes: [LuaToolsFix]

    private enum CodingKeys: String, CodingKey {
        case appID = "appid"
        case name
        case headerImage = "header_image"
        case fixes
    }
}

struct LuaToolsFix: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let tags: [LuaToolsFixTag]
    let hasManifest: Bool
    let hasFix: Bool
    let manifestFilename: String?
    let fixFilename: String?
    let createdAt: String?

    var availability: String {
        switch (hasManifest, hasFix) {
        case (true, true): return "Manifest + fix available"
        case (true, false): return "Manifest available"
        case (false, true): return "Fix files available"
        case (false, false): return "No downloadable files"
        }
    }

    var dateLabel: String {
        guard let createdAt else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: createdAt)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: createdAt)
        }
        guard let date else { return "" }
        if Calendar.current.component(.year, from: date) <= 1970 { return "" }
        let out = DateFormatter()
        out.dateFormat = "d MMM yyyy"
        return out.string(from: date)
    }
}

enum LuaToolsFixesError: LocalizedError {
    case http(Int, String)
    case noFixes
    case invalidResponse
    case network(String)
    case dailyLimit
    case downloadTooLarge

    var errorDescription: String? {
        switch self {
        case .http(let code, let detail):
            return detail.isEmpty ? "lua.tools returned HTTP \(code)." : detail
        case .noFixes:
            return "lua.tools has no fixes for this game."
        case .invalidResponse:
            return "lua.tools returned an unexpected response."
        case .network(let detail):
            return "Couldn't reach lua.tools: \(detail)"
        case .dailyLimit:
            return "Your lua.tools daily download limit has been reached."
        case .downloadTooLarge:
            return "The downloaded fix is too large."
        }
    }
}

actor LuaToolsFixesClient {
    static let shared = LuaToolsFixesClient()

    static let webURL = URL(string: "https://lua.tools/fixes")!
    static func webURL(appID: String) -> URL {
        URL(string: "https://lua.tools/fixes?appid=\(appID)") ?? webURL
    }

    private let session: URLSession
    private let baseURL = URL(string: "https://lua.tools")!
    private var cachedListings: (Date, LuaToolsFixListings)?
    private var cachedDetails: [String: LuaToolsFixDetail] = [:]

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "macSteam Config/0.9"]
        session = URLSession(configuration: cfg)
    }

    func listings(force: Bool = false) async throws -> LuaToolsFixListings {
        if !force, let cached = cachedListings,
           Date().timeIntervalSince(cached.0) < 60 * 60 {
            return cached.1
        }
        let data = try await get(path: "/api/denuvo/listings")
        do {
            let decoded = try JSONDecoder().decode(LuaToolsFixListings.self, from: data)
            if force { cachedDetails.removeAll() }
            cachedListings = (Date(), decoded)
            return decoded
        } catch {
            throw LuaToolsFixesError.invalidResponse
        }
    }

    func fixes(appID: String, force: Bool = false) async throws -> LuaToolsFixDetail {
        if !force, let cached = cachedDetails[appID] {
            return cached
        }
        do {
            let data = try await get(path: "/api/denuvo/fixes", query: ["appid": appID])
            let decoded = try JSONDecoder().decode(LuaToolsFixDetail.self, from: data)
            cachedDetails[appID] = decoded
            return decoded
        } catch let error as LuaToolsFixesError {
            throw error
        } catch {
            throw LuaToolsFixesError.invalidResponse
        }
    }

    /// Download the `manifest` slot of a fix. The API returns a short-lived signed
    /// R2 URL after checking the lua.tools account and daily limit.
    func downloadManifest(fixID: String) async throws -> Data {
        try await downloadSlot(fixID: fixID, slot: "manifest")
    }

    func downloadFix(fixID: String) async throws -> Data {
        try await downloadSlot(fixID: fixID, slot: "fix")
    }

    private func downloadSlot(fixID: String, slot: String) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/api/denuvo/download"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "fix", value: fixID),
            URLQueryItem(name: "slot", value: slot),
        ]
        let signed: SignedDownload
        do {
            let (data, status) = try await authorizedGet(url: comps.url!, token: nil)
            if status == 401 {
                let token = try await LuaToolsAuth.shared.accessToken(forceRefresh: true)
                let retry = try await authorizedGet(url: comps.url!, token: token)
                guard (200..<300).contains(retry.1) else {
                    throw mapDownloadStatus(retry.1, data: retry.0)
                }
                signed = try JSONDecoder().decode(SignedDownload.self, from: retry.0)
            } else {
                guard (200..<300).contains(status) else {
                    throw mapDownloadStatus(status, data: data)
                }
                signed = try JSONDecoder().decode(SignedDownload.self, from: data)
            }
        } catch let error as LuaToolsFixesError {
            throw error
        } catch let error as LuaToolsAuthError {
            throw error
        } catch {
            throw LuaToolsFixesError.invalidResponse
        }
        guard let url = URL(string: signed.url) else {
            throw LuaToolsFixesError.invalidResponse
        }
        LuaToolsLog.write("Downloading LuaTools fix \(fixID) (\(slot)).")
        let file: Data
        let response: URLResponse
        do {
            (file, response) = try await session.data(from: url)
        } catch {
            throw LuaToolsFixesError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LuaToolsFixesError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LuaToolsFixesError.http(http.statusCode, "")
        }
        guard file.count <= 256 * 1024 * 1024 else {
            throw LuaToolsFixesError.downloadTooLarge
        }
        LuaToolsLog.write("Downloaded \(file.count) bytes for fix \(fixID) (\(slot)).")
        return file
    }

    private func authorizedGet(url: URL,
                               token: String?) async throws -> (Data, Int) {
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
            throw LuaToolsFixesError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LuaToolsFixesError.invalidResponse
        }
        return (data, http.statusCode)
    }

    private func mapDownloadStatus(_ status: Int, data: Data) -> LuaToolsFixesError {
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0?["error"] as? String } ?? ""
        if status == 429 { return .dailyLimit }
        if status == 403, detail.lowercased().contains("limit") {
            return .dailyLimit
        }
        if status == 401 || status == 403 {
            return .http(status, detail.isEmpty ? "Sign in with Discord again." : detail)
        }
        return .http(status, detail)
    }

    private struct SignedDownload: Decodable {
        let url: String
    }

    private func get(path: String, query: [String: String] = [:]) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw LuaToolsFixesError.invalidResponse }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw LuaToolsFixesError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LuaToolsFixesError.invalidResponse
        }
        if http.statusCode == 404 { throw LuaToolsFixesError.noFixes }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error"] as? String } ?? ""
            throw LuaToolsFixesError.http(http.statusCode, detail)
        }
        return data
    }
}
