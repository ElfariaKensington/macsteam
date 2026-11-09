// Asks the dylib to re-read config.yaml and arm Steam's library refresh after a manifest install.
import Foundation

enum HubcapActivation {
    static func requestRefresh(timeout: TimeInterval = 8) async -> Bool {
        let token = UUID().uuidString
        do {
            try Paths.ensureDir(Paths.configDir)
            try (token + "\n").write(to: Paths.hubcapRefreshRequest,
                                     atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if let text = try? String(contentsOf: Paths.hubcapRefreshAck, encoding: .utf8) {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if let first = lines.first.map(String.init),
                   first.trimmingCharacters(in: .whitespacesAndNewlines) == token {
                    let status = lines.count > 1
                        ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    return status != "error"
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
