// Runs the bundled AchievementUploader against a game's own Steamworks shim.
import Foundation

enum SteamworksShim {
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
}

enum SteamAchievementUploader {
    struct Result {
        let ok: Bool
        let message: String
    }

    static func upload(appID: Int, ids: [String]) async -> Result {
        guard !ids.isEmpty else {
            return Result(ok: false, message: "No achievements were selected.")
        }
        guard let shim = SteamworksShim.find(appID: appID) else {
            return Result(ok: false,
                          message: "This game does not include a Steamworks library, so its "
                              + "achievements cannot be uploaded to your Steam profile.")
        }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "AchievementUploader") else {
            return Result(ok: false, message: "The achievement uploader helper is missing from the app.")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = helper
                process.arguments = ["--appid", String(appID), "--shim", shim.path,
                                     "--ids", ids.joined(separator: ",")]
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
