// Which service supplies Lua + manifests. Read on every call, so a change in
// Settings applies to the next add or store-page check without a restart.
import Foundation

enum LuaProvider: String, CaseIterable, Sendable {
    case luaTools
    case hubcap

    static let defaultsKey = "luaProvider"
    static let didChange = Notification.Name("com.macsteam.luaProviderChanged")

    var title: String {
        switch self {
        case .luaTools: return "LuaTools"
        case .hubcap: return "Hubcap"
        }
    }

    static var current: LuaProvider {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(LuaProvider.init(rawValue:)) ?? .luaTools
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
