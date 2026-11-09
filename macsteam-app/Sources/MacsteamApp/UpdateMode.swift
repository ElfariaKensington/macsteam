// User preference for Steam client updates. Defaults to allowed so a fresh
// install is not pinned unexpectedly; the Install pane applies the preference.
import Foundation

enum UpdateMode {
    static let defaultsKey = "allowSteamUpdates"

    static func allowsUpdates(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    static func setAllowsUpdates(_ allowed: Bool, defaults: UserDefaults = .standard) {
        defaults.set(allowed, forKey: defaultsKey)
    }

    /// Writes or removes Steam's `steam.cfg` update block to match the preference.
    static func apply() throws {
        if allowsUpdates() {
            try SteamInstaller.disableUpdateBlock()
        } else {
            try SteamInstaller.writeUpdateBlock()
        }
    }

    static func applyAndLog() {
        do {
            try apply()
        } catch {
            AppLog.write("update mode: \(error.localizedDescription)", category: "install")
        }
    }
}
