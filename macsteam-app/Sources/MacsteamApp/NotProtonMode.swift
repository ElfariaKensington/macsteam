// User preference for NotProton compatibility. On by default so a fresh install
// keeps Steam.app as the launcher while loading macSteam next to NotProton.
import Foundation

enum NotProtonMode {
    static let defaultsKey = "notProtonModeEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
