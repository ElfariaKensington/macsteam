import Foundation

enum HubcapCredentialStore {
    private static let defaultsKey = "hubcap.apiKey"

    static var apiKey: String? {
        guard let key = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            return nil
        }
        return key
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(key, forKey: defaultsKey)
    }

    static func remove() throws {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
