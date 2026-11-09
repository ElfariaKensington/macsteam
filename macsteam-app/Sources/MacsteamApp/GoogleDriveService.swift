// Google Drive sign-in and direct sync for the Cloud Saves cache.
import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

// MARK: - Legacy Keychain migration

enum CloudKeychain {
    private static let service = "com.macsteam.cloudsaves"

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// OAuth tokens live in a 0600 file instead of the Keychain. macSteam is ad-hoc
/// signed, so every rebuild changes the code identity and SecurityAgent would ask
/// for the login-keychain password. The file is per-user, and this keeps background
/// sync working across builds.
enum CloudTokenStore {
    private static let lock = NSLock()
    private static let migratedKey = "cloudSavesTokenMigratedFromKeychain"

    static func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: Paths.cloudSavesTokenFile)
    }

    static func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try Paths.ensureDir(Paths.configDir)
        try data.write(to: Paths.cloudSavesTokenFile, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.cloudSavesTokenFile.path)
    }

    static func delete() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: Paths.cloudSavesTokenFile)
        CloudKeychain.delete(account: GoogleDriveAuth.keychainAccount)
    }

    static func migrateFromKeychainIfNeeded() {
        if FileManager.default.fileExists(atPath: Paths.cloudSavesTokenFile.path) {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        if UserDefaults.standard.bool(forKey: migratedKey) { return }
        guard let data = CloudKeychain.load(account: GoogleDriveAuth.keychainAccount) else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        do {
            try save(data)
            CloudKeychain.delete(account: GoogleDriveAuth.keychainAccount)
            CloudSavesLog.write("Google Drive token migrated from Keychain to disk.")
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.macsteam.cloudSavesChanged"), object: nil)
        } catch {
            CloudSavesLog.write("Google Drive token migration failed: \(error.localizedDescription)")
            return
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}

enum CloudDriveError: LocalizedError {
    case oauth(String)
    case token(String)
    case http(Int, String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .oauth(let message): return "Google sign-in failed: \(message)"
        case .token(let message): return "Google Drive token error: \(message)"
        case .http(let code, let message):
            guard !message.isEmpty else { return "Google Drive returned HTTP \(code)." }
            return message.count > 400 ? String(message.prefix(400)) + "…" : message
        case .notConnected: return "Connect Google Drive first."
        }
    }
}

// MARK: - OAuth loopback

final class OAuthLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macsteam.oauth.loopback")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var expectedState = ""

    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CloudDriveError.oauth("Could not create the callback socket.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw CloudDriveError.oauth("Could not bind the callback socket.")
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else {
            close(fd)
            throw CloudDriveError.oauth("Could not read the callback port.")
        }
        listenFD = fd
        port = UInt16(bigEndian: out.sin_port)
    }

    func waitForCode(state: String, timeout: TimeInterval = 300) async throws -> String {
        expectedState = state
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            queue.async { [weak self] in self?.acceptLoop() }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failure(CloudDriveError.oauth("Sign-in timed out.")))
            }
        }
    }

    func stop() {
        finish(.failure(CloudDriveError.oauth("Sign-in cancelled.")))
    }

    private func acceptLoop() {
        while !isFinished {
            let fd = listenFD
            guard fd >= 0 else { return }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &len)
                }
            }
            if client < 0 { return }
            // Browsers open speculative connections and may not send a request
            // immediately; never let one block the real OAuth callback.
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(client)
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
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
            respond(client, status: "400 Bad Request", body: "Bad callback.")
            return
        }
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        // Browsers may probe /favicon.ico or /. Ignore those instead of aborting
        // the pending sign-in.
        if items["code"] == nil, items["error"] == nil, items["state"] == nil {
            respond(client, status: "404 Not Found", body: "Not the sign-in callback.")
            return
        }
        guard items["state"] == expectedState else {
            respond(client, status: "400 Bad Request", body: "State mismatch.")
            finish(.failure(CloudDriveError.oauth("State mismatch.")))
            return
        }
        if let error = items["error"], !error.isEmpty {
            respond(client, status: "200 OK", body: "Sign-in was cancelled. You can close this window.")
            finish(.failure(CloudDriveError.oauth(error)))
            return
        }
        guard let code = items["code"], !code.isEmpty else {
            respond(client, status: "400 Bad Request", body: "No authorization code.")
            finish(.failure(CloudDriveError.oauth("No authorization code.")))
            return
        }
        respond(client, status: "200 OK",
                body: "Google Drive is connected. You can close this window and return to macSteam.")
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
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        timeoutTask?.cancel()
        cont?.resume(with: result)
    }
}

// MARK: - Google auth

struct GoogleDriveTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum GoogleDriveAuth {
    struct OAuthClient: Decodable, Sendable {
        let clientID: String
        let clientSecret: String
    }

    static var isConfigured: Bool { (try? oauthClient()) != nil }

    /// Credentials are user-supplied and live outside the repository. Google
    /// desktop OAuth clients still need the secret for the token exchange.
    private static func oauthClient() throws -> OAuthClient {
        guard let data = try? Data(contentsOf: Paths.googleOAuthFile),
              let client = try? JSONDecoder().decode(OAuthClient.self, from: data),
              !client.clientID.isEmpty, !client.clientSecret.isEmpty else {
            throw CloudDriveError.oauth(
                "Google Drive isn't configured. Add your OAuth client ID and secret to "
                + "\(Paths.googleOAuthFile.path) as "
                + "{\"clientID\":\"…\",\"clientSecret\":\"…\"}.")
        }
        return client
    }

    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let keychainAccount = "google-drive"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let emailKey = "cloudSavesGoogleEmail"
    private static let folderIDKey = "cloudSavesGoogleFolderID"

    static var isConnected: Bool {
        (try? tokens()) != nil
    }

    static var cachedAccountEmail: String? {
        UserDefaults.standard.string(forKey: emailKey)
    }

    static var cachedFolderID: String? {
        UserDefaults.standard.string(forKey: folderIDKey)
    }

    static var driveFolderURL: URL {
        if let id = cachedFolderID, !id.isEmpty,
           let url = URL(string: "https://drive.google.com/drive/folders/\(id)") {
            return url
        }
        return URL(string: "https://drive.google.com/drive/my-drive")!
    }

    static func tokens() throws -> GoogleDriveTokens? {
        guard let data = CloudTokenStore.load() else { return nil }
        return try JSONDecoder().decode(GoogleDriveTokens.self, from: data)
    }

    static func disconnect() {
        CloudTokenStore.delete()
        UserDefaults.standard.removeObject(forKey: emailKey)
        UserDefaults.standard.removeObject(forKey: folderIDKey)
        CloudSavesLog.write("Google Drive disconnected.")
    }

    static func refreshAccountEmail() async {
        guard let token = try? await accessToken() else { return }
        var req = URLRequest(url: URL(string:
            "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            struct Response: Decodable {
                struct User: Decodable { let emailAddress: String? }
                let user: User
            }
            if let email = try JSONDecoder().decode(Response.self, from: data).user.emailAddress {
                UserDefaults.standard.set(email, forKey: emailKey)
                CloudSavesLog.write("Google Drive account: \(email)")
            }
        } catch {
            CloudSavesLog.write("Google Drive account lookup failed: \(error.localizedDescription)")
        }
    }

    static func connect() async throws -> GoogleDriveTokens {
        let client = try oauthClient()
        CloudSavesLog.write("Google Drive sign-in started.")
        let server = try OAuthLoopbackServer()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.port)/callback"
        let verifier = randomURLSafe(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(32)

        var comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = comps.url else { throw CloudDriveError.oauth("Could not build the sign-in URL.") }
        CloudSavesLog.write("Google Drive sign-in: opening browser on port \(server.port).")
        let waitTask = Task { try await server.waitForCode(state: state) }
        // Give the loopback listener its handler before the browser can call back.
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSWorkspace.shared.open(url)
        let code = try await waitTask.value
        CloudSavesLog.write("Google Drive sign-in: authorization code received.")
        let tokens = try await exchange(code: code, redirect: redirect, verifier: verifier)
        CloudSavesLog.write("Google Drive sign-in: tokens saved.")
        return tokens
    }

    static func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard var current = try tokens() else { throw CloudDriveError.notConnected }
        if !forceRefresh && current.expiresAt > Date().addingTimeInterval(60) {
            return current.accessToken
        }
        CloudSavesLog.write(forceRefresh
            ? "Google Drive token rejected; forcing refresh."
            : "Google Drive token expired; refreshing.")
        current = try await refresh(current)
        if let data = try? JSONEncoder().encode(current) {
            try CloudTokenStore.save(data)
        }
        return current.accessToken
    }

    private static func exchange(code: String, redirect: String,
                                 verifier: String) async throws -> GoogleDriveTokens {
        let client = try oauthClient()
        let body = form([
            "code": code,
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        let tokens = try await tokenRequest(body: body)
        guard !tokens.refreshToken.isEmpty else {
            throw CloudDriveError.token(
                "Google did not return a refresh token. Remove macSteam from your "
                + "Google account permissions and connect again.")
        }
        try CloudTokenStore.save(try JSONEncoder().encode(tokens))
        return tokens
    }

    private static func refresh(_ current: GoogleDriveTokens) async throws -> GoogleDriveTokens {
        let client = try oauthClient()
        let body = form([
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ])
        var next = try await tokenRequest(body: body)
        if next.refreshToken.isEmpty { next.refreshToken = current.refreshToken }
        return next
    }

    private static func tokenRequest(body: Data) async throws -> GoogleDriveTokens {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.token("No response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            CloudSavesLog.write("Google token endpoint returned HTTP \(http.statusCode).")
            throw CloudDriveError.token("HTTP \(http.statusCode): \(detail)")
        }
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.access_token.isEmpty else {
            throw CloudDriveError.token("Missing access token.")
        }
        return GoogleDriveTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in ?? 3600)))
    }

    private static func form(_ items: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }

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

// MARK: - Drive client

struct CloudProviderSyncReport: Sendable {
    var uploaded = 0
    var downloaded = 0
    var skipped = 0
    var renamed = 0
    var conflicts = 0
    var removed = 0
    var remoteFiles = 0
    var errors: [String] = []

    var summary: String {
        let noun = "file\(remoteFiles == 1 ? "" : "s")"
        if !errors.isEmpty {
            return "Drive: \(uploaded + downloaded) synced, "
                + "\(errors.count) error\(errors.count == 1 ? "" : "s")"
        }
        if uploaded == 0 && downloaded == 0 && renamed == 0 && conflicts == 0
            && removed == 0 {
            return remoteFiles == 0
                ? "Drive: no files yet"
                : "Drive: up to date · \(remoteFiles) \(noun)"
        }
        var text = "Drive: \(uploaded) up · \(downloaded) down"
        if renamed > 0 { text += " · \(renamed) renamed" }
        if conflicts > 0 {
            text += " · \(conflicts) conflict\(conflicts == 1 ? "" : "s")"
        }
        if removed > 0 { text += " · \(removed) removed" }
        text += " · \(remoteFiles) \(noun)"
        return text
    }
}

actor GoogleDriveClient {
    private let session: URLSession
    private var rootID: String?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        session = URLSession(configuration: cfg)
    }

    func sync(localRoot: URL, apps: Set<Int>,
              keepingApps: Set<Int>? = nil) async throws -> CloudProviderSyncReport {
        var report = CloudProviderSyncReport()
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let root = try await ensureRoot()
        let keep = keepingApps ?? apps
        let remoteAll = try await listRemote(rootID: root)
        var remote: [RemoteFile] = []
        for file in remoteAll {
            guard let appID = Int(file.appID) else {
                do {
                    try await trash(file.id)
                    report.removed += 1
                } catch {
                    report.errors.append("Could not remove \(file.name): "
                                         + error.localizedDescription)
                }
                continue
            }
            if apps.contains(appID) {
                remote.append(file)
                continue
            }
            // Paused games keep their Drive files; only games removed from
            // macSteam are trashed.
            if keep.contains(appID) { continue }
            do {
                try await trash(file.id)
                report.removed += 1
                CloudSavesLog.write("Drive remove: \(file.name) "
                                    + "(game is not added to macSteam; moved to Trash)")
            } catch {
                report.errors.append("Could not remove \(file.name): "
                                     + error.localizedDescription)
                CloudSavesLog.write("Drive remove failed for \(file.name): "
                                    + error.localizedDescription)
            }
        }
        let locals = localEntries(root: localRoot).filter {
            guard let appID = Int($0.appID) else { return false }
            return apps.contains(appID)
        }
        CloudSavesLog.write("Drive: root=\(root), remote=\(remote.count), local=\(locals.count).")

        var remoteKeys = Set(remote.map(\.key))
        var remoteByKey: [String: RemoteFile] = [:]
        var duplicateIDs: [String] = []
        for file in remote {
            if let existing = remoteByKey[file.key] {
                CloudSavesLog.write("Drive: duplicate remote entry for \(file.key); "
                                    + "keeping the newest copy.")
                if file.mtime > existing.mtime {
                    duplicateIDs.append(existing.id)
                    remoteByKey[file.key] = file
                } else {
                    duplicateIDs.append(file.id)
                }
            } else {
                remoteByKey[file.key] = file
            }
        }
        for id in duplicateIDs {
            do {
                try await trash(id)
                report.removed += 1
                CloudSavesLog.write("Drive remove: duplicate file \(id) moved to Trash")
            } catch {
                report.errors.append("Could not remove duplicate Drive file: "
                                     + error.localizedDescription)
            }
        }
        for entry in locals {
            let key = entry.key
            let wantedName = displayName(entry)
            do {
                if let file = remoteByKey.removeValue(forKey: key) {
                    if file.name != wantedName {
                        try await rename(file.id, to: wantedName)
                        report.renamed += 1
                        CloudSavesLog.write("Drive rename: \(file.name) -> \(wantedName)")
                    }
                    if entry.mtime > file.mtime + 2 {
                        try await backupRemote(file, root: localRoot)
                        report.conflicts += 1
                        try await upload(entry, rootID: root, existing: file.id)
                        report.uploaded += 1
                        CloudSavesLog.write("Drive upload: \(wantedName) "
                                            + "(\(fileSize(entry.url)) bytes; "
                                            + "remote copy backed up)")
                    } else if file.mtime > entry.mtime + 2 {
                        try backupLocal(entry, root: localRoot)
                        report.conflicts += 1
                        try await download(file, to: entry.url)
                        report.downloaded += 1
                        CloudSavesLog.write("Drive download: \(wantedName) "
                                            + "(remote is newer; local copy backed up)")
                    } else {
                        report.skipped += 1
                    }
                } else {
                    try await upload(entry, rootID: root, existing: nil)
                    report.uploaded += 1
                    remoteKeys.insert(key)
                    CloudSavesLog.write("Drive upload: \(wantedName) "
                                        + "(\(fileSize(entry.url)) bytes, new)")
                }
            } catch {
                report.errors.append("\(wantedName): \(error.localizedDescription)")
                CloudSavesLog.write("Drive error for \(wantedName): "
                                    + "\(error.localizedDescription)")
            }
        }

        for file in remoteByKey.values {
            var target = localRoot.appendingPathComponent(file.account, isDirectory: true)
                .appendingPathComponent(file.appID, isDirectory: true)
            if file.relative.hasPrefix("ac/GameInstall/saves/") {
                target = target.appendingPathComponent(file.relative)
            } else {
                target = target.appendingPathComponent("remote", isDirectory: true)
                    .appendingPathComponent(file.relative)
            }
            do {
                try await download(file, to: target)
                report.downloaded += 1
                CloudSavesLog.write("Drive download: \(displayName(file)) (new remote file)")
            } catch {
                report.errors.append("\(displayName(file)): \(error.localizedDescription)")
                CloudSavesLog.write("Drive error for \(displayName(file)): "
                                    + "\(error.localizedDescription)")
            }
        }
        report.remoteFiles = remoteKeys.count
        CloudSavesLog.write("Drive result: \(report.summary)")
        return report
    }

    // MARK: Folders

    private func ensureRoot() async throws -> String {
        if let rootID { return rootID }
        let query = "name = 'macSteam Cloud Saves' and mimeType = 'application/vnd.google-apps.folder' "
            + "and trashed = false and 'root' in parents"
        let data = try await get("/drive/v3/files", query: [
            "q": query,
            "fields": "files(id,name)",
            "pageSize": "10",
        ])
        if let root = try JSONDecoder().decode(FileList.self, from: data).files.first {
            rootID = root.id
            UserDefaults.standard.set(root.id, forKey: "cloudSavesGoogleFolderID")
            CloudSavesLog.write("Drive: using existing folder \(root.id).")
            return root.id
        }
        let metadata: [String: Any] = [
            "name": "macSteam Cloud Saves",
            "mimeType": "application/vnd.google-apps.folder",
            "parents": ["root"],
        ]
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let created = try await request(path: "/drive/v3/files?fields=id",
                                        method: "POST", body: body,
                                        contentType: "application/json")
        guard let id = (try? JSONSerialization.jsonObject(with: created) as? [String: Any])
            .flatMap({ $0?["id"] as? String }) else {
            throw CloudDriveError.http(500, "Could not create the Google Drive folder.")
        }
        rootID = id
        UserDefaults.standard.set(id, forKey: "cloudSavesGoogleFolderID")
        CloudSavesLog.write("Drive: created folder \(id).")
        return id
    }

    private func listRemote(rootID: String) async throws -> [RemoteFile] {
        var out: [RemoteFile] = []
        var pageToken: String?
        repeat {
            var query: [String: String] = [
                "q": "'\(rootID)' in parents and trashed = false",
                "fields": "nextPageToken,files(id,name,size,modifiedTime,appProperties)",
                "pageSize": "1000",
            ]
            if let pageToken { query["pageToken"] = pageToken }
            let data = try await get("/drive/v3/files", query: query)
            let page = try JSONDecoder().decode(FileList.self, from: data)
            for file in page.files {
                guard let props = file.appProperties,
                      let account = props["account"],
                      let appID = props["appid"],
                      let relative = props["relpath"],
                      let mtime = props["mtime"].flatMap(Double.init),
                      account.allSatisfy(\.isNumber),
                      appID.allSatisfy(\.isNumber),
                      !relative.isEmpty,
                      !relative.hasPrefix("/"),
                      !relative.split(separator: "/").contains("..") else { continue }
                out.append(RemoteFile(id: file.id, account: account, appID: appID,
                                      relative: relative, mtime: mtime,
                                      size: Int(file.size ?? "") ?? 0, name: file.name))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    // MARK: Transfers

    private func upload(_ entry: LocalEntry, rootID: String, existing: String?) async throws {
        let metadata: [String: Any] = [
            "name": displayName(entry),
            "appProperties": [
                "account": entry.account,
                "appid": entry.appID,
                "relpath": entry.relative,
                "mtime": String(entry.mtime),
            ],
        ]
        var meta = metadata
        if existing == nil { meta["parents"] = [rootID] }
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        let fileData = try Data(contentsOf: entry.url, options: .mappedIfSafe)
        let boundary = "macSteamBoundary\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metaData)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let path: String
        let method: String
        if let existing {
            path = "/upload/drive/v3/files/\(existing)?uploadType=multipart&fields=id"
            method = "PATCH"
        } else {
            path = "/upload/drive/v3/files?uploadType=multipart&fields=id"
            method = "POST"
        }
        _ = try await request(path: path, method: method, body: body,
                              contentType: "multipart/related; boundary=\(boundary)")
    }

    private func trash(_ id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["trashed": true])
        _ = try await request(path: "/drive/v3/files/\(id)?fields=id",
                              method: "PATCH", body: body, contentType: "application/json")
    }

    private func rename(_ id: String, to name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await request(path: "/drive/v3/files/\(id)?fields=id",
                              method: "PATCH", body: body, contentType: "application/json")
    }

    private func backupLocal(_ entry: LocalEntry, root: URL) throws {
        let target = conflictURL(account: entry.account, appID: entry.appID,
                                 relative: entry.relative, label: "local", root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: entry.url, to: target)
    }

    private func backupRemote(_ file: RemoteFile, root: URL) async throws {
        let target = conflictURL(account: file.account, appID: file.appID,
                                 relative: file.relative, label: "drive", root: root)
        try await download(file, to: target)
    }

    private func conflictURL(account: String, appID: String, relative: String,
                             label: String, root: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return root
            .appendingPathComponent(".conflicts", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(label)", isDirectory: true)
            .appendingPathComponent(account, isDirectory: true)
            .appendingPathComponent(appID, isDirectory: true)
            .appendingPathComponent(relative)
    }

    private func displayName(_ entry: LocalEntry) -> String {
        let relative = entry.relative.replacingOccurrences(of: "/", with: "_")
        return "\(entry.account)_\(entry.appID)_\(relative)"
    }

    private func displayName(_ file: RemoteFile) -> String {
        let relative = file.relative.replacingOccurrences(of: "/", with: "_")
        return "\(file.account)_\(file.appID)_\(relative)"
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    private func download(_ file: RemoteFile, to url: URL) async throws {
        let query: [String: String] = ["alt": "media"]
        let data = try await get("/drive/v3/files/\(file.id)", query: query)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".macsteam-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: file.mtime)], ofItemAtPath: url.path)
    }

    // MARK: HTTP

    private func get(_ path: String, query: [String: String]) async throws -> Data {
        var comps = URLComponents(string: "https://www.googleapis.com\(path)")!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await request(url: comps.url!, method: "GET", body: nil, contentType: nil)
    }

    private func request(path: String, method: String, body: Data?,
                         contentType: String?) async throws -> Data {
        try await request(url: URL(string: "https://www.googleapis.com\(path)")!,
                          method: method, body: body, contentType: contentType)
    }

    private func request(url: URL, method: String, body: Data?,
                         contentType: String?) async throws -> Data {
        for attempt in 0..<2 {
            let token = try await GoogleDriveAuth.accessToken()
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            req.httpBody = body
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw CloudDriveError.http(0, "No HTTP response.")
            }
            if http.statusCode == 401 && attempt == 0 {
                _ = try? await GoogleDriveAuth.accessToken(forceRefresh: true)
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                CloudSavesLog.write("Drive HTTP \(http.statusCode) for \(method) "
                                    + "\(url.path): \(detail.prefix(500))")
                throw CloudDriveError.http(http.statusCode, detail)
            }
            return data
        }
        throw CloudDriveError.http(401, "Google Drive authorization failed.")
    }

    // MARK: Local walk

    private struct LocalEntry {
        let url: URL
        let account: String
        let appID: String
        let relative: String
        let mtime: Double
        let size: Int
        var key: String { "\(account)|\(appID)|\(relative)" }
    }

    private func localEntries(root: URL) -> [LocalEntry] {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [LocalEntry] = []
        for case let url as URL in en {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey, .fileSizeKey]),
                values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let fileParts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard fileParts.count > rootParts.count,
                  Array(fileParts.prefix(rootParts.count)) == rootParts else { continue }
            let relParts = Array(fileParts.dropFirst(rootParts.count))
            guard relParts.count >= 4,
                  relParts[0].allSatisfy(\.isNumber),
                  relParts[1].allSatisfy(\.isNumber) else { continue }
            let account = relParts[0]
            let appID = relParts[1]
            let rawRelative = relParts[2...].joined(separator: "/")
            // Keep the historical Drive key for Steam's remote/ folder (no
            // "remote/" prefix), while CrossOver saves keep their path.
            let relative: String
            if rawRelative.hasPrefix("remote/") {
                relative = String(rawRelative.dropFirst("remote/".count))
            } else if rawRelative.hasPrefix("ac/GameInstall/saves/") {
                relative = rawRelative
            } else {
                continue
            }
            guard !relative.isEmpty else { continue }
            result.append(LocalEntry(
                url: url, account: account, appID: appID, relative: relative,
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: values.fileSize ?? 0))
        }
        return result
    }

    private struct RemoteFile {
        let id: String
        let account: String
        let appID: String
        let relative: String
        let mtime: Double
        let size: Int
        let name: String
        var key: String { "\(account)|\(appID)|\(relative)" }
    }

    private struct DriveFile: Decodable {
        let id: String
        let name: String
        let size: String?
        let modifiedTime: String?
        let appProperties: [String: String]?
    }

    private struct FileList: Decodable {
        let files: [DriveFile]
        let nextPageToken: String?
    }
}

// MARK: - Combined provider sync

enum CloudDriveSync {
    static func sync(settings: CloudSavesSettings,
                     apps: Set<Int>,
                     keepingApps: Set<Int>? = nil) async -> CloudProviderSyncReport {
        switch settings.provider {
        case .folder:
            return CloudProviderSyncReport()
        case .gdrive:
            guard GoogleDriveAuth.isConnected else {
                CloudSavesLog.write("Drive: not connected.")
                return CloudProviderSyncReport(errors: ["Connect Google Drive in Cloud Saves settings."])
            }
            do {
                return try await GoogleDriveClient().sync(localRoot: Paths.cloudSavesCacheDir,
                                                          apps: apps,
                                                          keepingApps: keepingApps)
            } catch {
                CloudSavesLog.write("Drive error: \(error.localizedDescription)")
                return CloudProviderSyncReport(errors: [error.localizedDescription])
            }
        }
    }
}
