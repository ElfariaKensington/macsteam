// Canonical filesystem locations shared by the dylib and this app.

import Foundation

enum Paths {
    static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/macsteam", isDirectory: true)
    }
    static var configFile: URL {
        configDir.appendingPathComponent("config.yaml")
    }
    static var appLog: URL {
        configDir.appendingPathComponent("macsteam.log")
    }

    static var configBackupDir: URL {
        configDir.appendingPathComponent("backups", isDirectory: true)
    }

    static var luaDir: URL {
        configDir.appendingPathComponent("lua", isDirectory: true)
    }

    static var signaturesDir: URL {
        configDir.appendingPathComponent("signatures", isDirectory: true)
    }

    // Store-page bridge handshake. The dylib watches the request and answers in the ack.
    static var hubcapRefreshRequest: URL {
        configDir.appendingPathComponent("hubcap-refresh.request")
    }
    static var hubcapRefreshAck: URL {
        configDir.appendingPathComponent("hubcap-refresh.ack")
    }
    static var hubcapBridgeLock: URL {
        configDir.appendingPathComponent("hubcap-bridge.lock")
    }
    static var hubcapBridgePath: URL {
        configDir.appendingPathComponent("hubcap-bridge.path")
    }
    static var hubcapBridgeLog: URL {
        configDir.appendingPathComponent("hubcap-bridge.log")
    }

    static var cloudSavesLock: URL {
        configDir.appendingPathComponent("cloud-saves.lock")
    }
    static var cloudSavesLog: URL {
        configDir.appendingPathComponent("cloud-saves.log")
    }
    static var cloudSavesCacheDir: URL {
        configDir.appendingPathComponent("cloud-saves-cache", isDirectory: true)
    }
    static var cloudSavesTokenFile: URL {
        configDir.appendingPathComponent("cloud-saves-token.json")
    }
    /// Local-only Google OAuth client credentials. Never commit this file.
    static var googleOAuthFile: URL {
        configDir.appendingPathComponent("google-oauth.json")
    }
    static var luaToolsAuthFile: URL {
        configDir.appendingPathComponent("lua-tools-auth.json")
    }
    static var luaToolsLog: URL {
        configDir.appendingPathComponent("lua-tools.log")
    }

    // Steam only opens its CEF debugging port when this marker exists at launch.
    static var cefDebugMarker: URL {
        innerClientMacOS.appendingPathComponent(".cef-enable-remote-debugging")
    }

    static var steamRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    static var depotCache: URL {
        steamRoot.appendingPathComponent("depotcache", isDirectory: true)
    }

    static var steamApp: URL {
        URL(fileURLWithPath: "/Applications/Steam.app", isDirectory: true)
    }
    static var launcherApp: URL {
        URL(fileURLWithPath: "/Applications/macSteam.app", isDirectory: true)
    }
    static var steamAppExecutable: URL {
        steamApp.appendingPathComponent("Contents/MacOS/steam_osx")
    }
    static var steamAppInfoPlist: URL {
        steamApp.appendingPathComponent("Contents/Info.plist")
    }
    static var steamAppInjectedDylib: URL {
        steamApp.appendingPathComponent("Contents/MacOS/macsteam.dylib")
    }
    /// Same binary under NotProton's filename so its foreign-dylib check ignores us.
    static var notProtonCompatibleDylib: URL {
        configDir.appendingPathComponent("notproton.dylib")
    }

    static var innerClientMacOS: URL {
        steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS", isDirectory: true)
    }

    static var packageDir: URL {
        innerClientMacOS.appendingPathComponent("package", isDirectory: true)
    }

    static var steamCfgRoot: URL {
        steamRoot.appendingPathComponent("steam.cfg")
    }
    static var steamCfgInner: URL {
        innerClientMacOS.appendingPathComponent("steam.cfg")
    }

    static let defaultInjectionPackage = 20200

    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
