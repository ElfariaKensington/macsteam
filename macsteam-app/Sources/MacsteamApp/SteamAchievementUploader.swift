// Runs the bundled AchievementUploader against a game's own Steamworks shim.
import Foundation

enum SteamworksShim {
    static func isArm64(_ url: URL) -> Bool {
        let result = Subprocess.run("/usr/bin/lipo", ["-info", url.path])
        return result.code == 0 && result.stdout.contains("arm64")
    }

    static func find(appID: Int) -> URL? {
        guard let root = SteamLibrary.installDir(appID: appID) else { return nil }
        let fm = FileManager.default
        let skipped: Set<String> = ["Data", "StreamingAssets", "Resources", "Content", "logs"]
        var queue: [(URL, Int)] = [(root, 0)]

        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard depth <= 8 else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                if name == "libsteam_api.dylib" || name == "steam_api.dylib" {
                    return entry
                }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory && !skipped.contains(name) {
                    queue.append((entry, depth + 1))
                }
            }
        }
        return nil
    }

    /// Windows games ship a PE steam_api64.dll that this arm64 helper cannot
    /// dlopen. Steamworks shims are app-agnostic, so use any arm64
    /// libsteam_api.dylib from another installed game with the target app ID.
    static func nativeShim(appID: Int) -> URL? {
        if let own = find(appID: appID), isArm64(own) { return own }
        return genericShim()
    }

    static func genericShim() -> URL? {
        let fm = FileManager.default
        let skipped: Set<String> = ["Data", "StreamingAssets", "Resources", "Content",
                                    "logs", "node_modules"]
        for root in SteamLibrary.libraryRoots() {
            let common = root.appendingPathComponent("steamapps/common", isDirectory: true)
            guard let games = try? fm.contentsOfDirectory(
                at: common, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for game in games {
                var queue: [(URL, Int)] = [(game, 0)]
                while !queue.isEmpty {
                    let (directory, depth) = queue.removeFirst()
                    guard depth <= 7 else { continue }
                    guard let entries = try? fm.contentsOfDirectory(
                        at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]) else { continue }
                    for entry in entries {
                        let name = entry.lastPathComponent
                        if (name == "libsteam_api.dylib" || name == "steam_api.dylib"),
                           isArm64(entry) {
                            return entry
                        }
                        let isDirectory = (try? entry.resourceValues(
                            forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if isDirectory && !skipped.contains(name) {
                            queue.append((entry, depth + 1))
                        }
                    }
                }
            }
        }
        return nil
    }
}

enum SteamAchievementUploader {
    struct Result {
        let ok: Bool
        let message: String
    }

    static func upload(appID: Int, ids: [String], allIDs: [String] = []) async -> Result {
        guard !ids.isEmpty else {
            return Result(ok: false, message: "No achievements were selected.")
        }
        guard let shim = SteamworksShim.nativeShim(appID: appID) else {
            return Result(ok: false,
                          message: "This game's Steamworks library cannot be loaded by macSteam. "
                              + "Install a native Steam game that ships libsteam_api.dylib, then try again.")
        }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "AchievementUploader") else {
            return Result(ok: false, message: "The achievement uploader helper is missing from the app.")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = helper
                var arguments = ["--appid", String(appID), "--shim", shim.path,
                                 "--ids", ids.joined(separator: ",")]
                if !allIDs.isEmpty {
                    arguments += ["--all", allIDs.joined(separator: ",")]
                }
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let ok = object["ok"] as? Bool,
                       let message = object["message"] as? String {
                        continuation.resume(returning: Result(ok: ok, message: message))
                    } else {
                        continuation.resume(returning: Result(
                            ok: false,
                            message: "Steam did not return a usable response from the uploader."))
                    }
                } catch {
                    continuation.resume(returning: Result(ok: false, message: error.localizedDescription))
                }
            }
        }
    }
}
