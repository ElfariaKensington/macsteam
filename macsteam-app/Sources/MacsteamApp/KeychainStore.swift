import Foundation
import Security

enum KeychainStore {
    private static let service = "com.macsteam.hubcap"

    static func read(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError(status: updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery.merge(updateAttributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError(status: addStatus)
            }
        default:
            throw KeychainStoreError(status: status)
        }
    }

    static func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }
}

struct KeychainStoreError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return message ?? "Keychain error (status \(status))."
    }
}
