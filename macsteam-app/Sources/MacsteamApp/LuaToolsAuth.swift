// LuaTools / Supabase Discord sign-in and token storage for fix downloads.
//
// The browser OAuth redirect is the same loopback URL the LuaTools desktop app
// uses. Tokens are kept in a 0600 file because macSteam is ad-hoc signed and a
// Keychain item would trigger a login-password prompt after every rebuild.
import AppKit
import CryptoKit
import Darwin
import Foundation

enum LuaToolsLog {
    static func write(_ message: String) {
        AppLog.write(message, category: "luatools")
    }
}

enum LuaToolsAuthError: LocalizedError {
    case notSignedIn
    case portInUse
    case timeout
    case cancelled(String)
    case http(Int, String)
    case invalidResponse
    case network(String)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with Discord first."
        case .portInUse:
            return "Port 53789 is in use. Quit LuaTools (or any app using that port) and try again."
        case .timeout:
            return "Discord sign-in timed out."
        case .cancelled(let detail):
            return detail.isEmpty ? "Discord sign-in was cancelled." : detail
        case .http(let code, let detail):
            return detail.isEmpty ? "lua.tools returned HTTP \(code)." : detail
        case .invalidResponse:
            return "lua.tools returned an unexpected auth response."
        case .network(let detail):
            return "Couldn't reach lua.tools: \(detail)"
        case .sessionExpired:
            return "Your lua.tools session expired. Sign in with Discord again."
        }
    }
}

struct LuaToolsSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var displayName: String
    var email: String
}

actor LuaToolsAuth {
    static let shared = LuaToolsAuth()

    static let supabaseURL = URL(string: "https://db.lua.tools")!
    static let apiBaseURL = URL(string: "https://lua.tools")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
        + "eyJpYXQiOjE3NzYwMzkzNzYsImV4cCI6MTg5MzQ1NjAwMCwicm9sZSI6ImFub24iLCJpc3MiOiJzdXBhYmFzZSJ9."
        + "f_-K38u3odjltP-g_67FVmG32Vg-_-k-lNBvIaVUVBM"
    static let callbackPort: UInt16 = 53789
    static let callbackURL = "http://localhost:53789/callback"

    private let session: URLSession
    private var cached: LuaToolsSession?
    private var loaded = false
    private var refreshTask: Task<LuaToolsSession, Error>?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "macSteam Config/0.9"]
        session = URLSession(configuration: cfg)
    }

    // MARK: - Session state

    func isSignedIn() -> Bool {
        loadIfNeeded()
        return cached != nil
    }

    func accountLabel() -> String? {
        loadIfNeeded()
        guard let cached else { return nil }
        return cached.displayName.isEmpty ? cached.email : cached.displayName
    }

    func accountEmail() -> String? {
        loadIfNeeded()
        return cached?.email.isEmpty == false ? cached?.email : nil
    }

    func signOut() {
        cached = nil
        loaded = true
        try? FileManager.default.removeItem(at: Paths.luaToolsAuthFile)
        LuaToolsLog.write("Discord signed out.")
    }

    // MARK: - Sign in

    func signIn() async throws -> LuaToolsSession {
        LuaToolsLog.write("Discord sign-in started.")
        let server: LuaToolsLoopbackServer
        do {
            server = try LuaToolsLoopbackServer(port: Self.callbackPort)
        } catch LuaToolsLoopbackServer.StartError.portInUse {
            throw LuaToolsAuthError.portInUse
        } catch {
            throw LuaToolsAuthError.network(error.localizedDescription)
        }
        defer { server.stop() }

        let verifier = Self.randomURLSafe(48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(url: Self.supabaseURL.appendingPathComponent("auth/v1/authorize"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: "discord"),
            URLQueryItem(name: "redirect_to", value: Self.callbackURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let url = comps.url else { throw LuaToolsAuthError.invalidResponse }
        LuaToolsLog.write("Discord sign-in: opening browser.")
        NSWorkspace.shared.open(url)
        let code = try await server.waitForCode()
        LuaToolsLog.write("Discord sign-in: authorization code received.")
        let newSession = try await exchange(code: code, verifier: verifier)
        cached = newSession
        loaded = true
        try save(newSession)
        LuaToolsLog.write("Discord sign-in complete: \(newSession.displayName).")
        return newSession
    }

    // MARK: - Tokens

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        loadIfNeeded()
        guard let current = cached else { throw LuaToolsAuthError.notSignedIn }
        if !forceRefresh, current.expiresAt > Date().addingTimeInterval(120) {
            return current.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        let task = Task { try await self.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        cached = refreshed
        try save(refreshed)
        return refreshed.accessToken
    }

    private func refresh(_ current: LuaToolsSession) async throws -> LuaToolsSession {
        LuaToolsLog.write("Refreshing Discord session.")
        let body = try JSONSerialization.data(withJSONObject: [
            "refresh_token": current.refreshToken,
        ])
        let response = try await tokenRequest(grant: "refresh_token", body: body)
        var next = try Self.session(from: response, previous: current)
        if next.refreshToken.isEmpty { next.refreshToken = current.refreshToken }
        return next
    }

    private func exchange(code: String, verifier: String) async throws -> LuaToolsSession {
        let body = try JSONSerialization.data(withJSONObject: [
            "auth_code": code,
            "code_verifier": verifier,
        ])
        let response = try await tokenRequest(grant: "pkce", body: body)
        return try Self.session(from: response, previous: nil)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let user: User?

        struct User: Decodable {
            let email: String?
            let user_metadata: Metadata?
        }
        struct Metadata: Decodable {
            let full_name: String?
            let name: String?
            let custom_claims: Claims?
        }
        struct Claims: Decodable {
            let global_name: String?
        }
    }

    private static func session(from response: TokenResponse,
                                previous: LuaToolsSession?) throws -> LuaToolsSession {
        guard !response.access_token.isEmpty else { throw LuaToolsAuthError.invalidResponse }
        let meta = response.user?.user_metadata
        let name = meta?.custom_claims?.global_name
            ?? meta?.full_name
            ?? meta?.name
            ?? response.user?.email
            ?? previous?.displayName
            ?? "Discord account"
        let email = response.user?.email ?? previous?.email ?? ""
        return LuaToolsSession(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previous?.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600)),
            displayName: name,
            email: email)
    }

    private func tokenRequest(grant: String, body: Data) async throws -> TokenResponse {
        var comps = URLComponents(url: Self.supabaseURL.appendingPathComponent("auth/v1/token"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LuaToolsAuthError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LuaToolsAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error_description"] as? String ?? $0?["msg"] as? String } ?? ""
            LuaToolsLog.write("Discord token request failed: HTTP \(http.statusCode).")
            if (http.statusCode == 400 || http.statusCode == 401),
               grant == "refresh_token" {
                cached = nil
                loaded = true
                try? FileManager.default.removeItem(at: Paths.luaToolsAuthFile)
                throw LuaToolsAuthError.sessionExpired
            }
            throw LuaToolsAuthError.http(http.statusCode, detail)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw LuaToolsAuthError.invalidResponse
        }
    }

    // MARK: - Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Paths.luaToolsAuthFile),
              let decoded = try? JSONDecoder().decode(LuaToolsSession.self, from: data) else {
            return
        }
        cached = decoded
    }

    private func save(_ value: LuaToolsSession) throws {
        try Paths.ensureDir(Paths.configDir)
        let data = try JSONEncoder().encode(value)
        try data.write(to: Paths.luaToolsAuthFile, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.luaToolsAuthFile.path)
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback callback

final class LuaToolsLoopbackServer: @unchecked Sendable {
    enum StartError: Error {
        case portInUse
        case failed
    }

    private let queue = DispatchQueue(label: "com.macsteam.luatools.oauth")
    private let lock = NSLock()
    private var fd4: Int32 = -1
    private var fd6: Int32 = -1
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(port: UInt16) throws {
        fd4 = Self.listenIPv4(port: port)
        fd6 = Self.listenIPv6(port: port)
        guard fd4 >= 0, fd6 >= 0 else {
            if fd4 >= 0 { close(fd4) }
            if fd6 >= 0 { close(fd6) }
            throw StartError.portInUse
        }
    }

    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            queue.async { [weak self] in self?.acceptLoop() }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failure(LuaToolsAuthError.timeout))
            }
        }
    }

    func stop() {
        finish(.failure(LuaToolsAuthError.cancelled("")))
    }

    private static func listenIPv4(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private static func listenIPv6(port: UInt16) -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        let loopback = in6addr_loopback
        addr.sin6_addr = loopback
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private func acceptLoop() {
        while !isFinished {
            let a = fd4
            let b = fd6
            guard a >= 0 || b >= 0 else { return }
            var descriptors = [
                pollfd(fd: a, events: Int16(POLLIN), revents: 0),
                pollfd(fd: b, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            for descriptor in descriptors where descriptor.revents != 0 {
                guard descriptor.fd >= 0 else { continue }
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let client = withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(descriptor.fd, $0, &length)
                    }
                }
                guard client >= 0 else { continue }
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                           socklen_t(MemoryLayout<timeval>.size))
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.handleClient(client)
                }
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil,
              let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://localhost\(target)") else {
            respond(client, status: "400 Bad Request", body: "Bad callback.")
            return
        }
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        if items["code"] == nil, items["error_description"] == nil, items["error"] == nil {
            respond(client, status: "404 Not Found", body: "Not the sign-in callback.")
            return
        }
        if let error = items["error_description"] ?? items["error"], !error.isEmpty {
            respond(client, status: "200 OK",
                    body: "Discord sign-in was cancelled. You can close this window.")
            finish(.failure(LuaToolsAuthError.cancelled(error)))
            return
        }
        guard let code = items["code"], !code.isEmpty else {
            respond(client, status: "400 Bad Request", body: "No authorization code.")
            finish(.failure(LuaToolsAuthError.invalidResponse))
            return
        }
        respond(client, status: "200 OK",
                body: "Discord sign-in is complete. You can close this window and return to macSteam.")
        finish(.success(code))
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>macSteam</title>"
            + "<body style='font:15px -apple-system;padding:40px'>\(body)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = write(client, bytes.withUnsafeBytes { $0.baseAddress!.advanced(by: sent) },
                          bytes.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        if fd4 >= 0 { shutdown(fd4, SHUT_RDWR); close(fd4); fd4 = -1 }
        if fd6 >= 0 { shutdown(fd6, SHUT_RDWR); close(fd6); fd6 = -1 }
        timeoutTask?.cancel()
        cont?.resume(with: result)
    }
}
