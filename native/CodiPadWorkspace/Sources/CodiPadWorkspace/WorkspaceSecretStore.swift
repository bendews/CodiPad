import Foundation
import Security

public struct WorkspaceSecretStoreError: Error, Equatable {
    public let code: String
    public let message: String
    public let status: OSStatus?
}

/// App-private extension credentials. The trusted bridge serializes requests to this store.
public final class WorkspaceSecretStore {
    internal struct Keychain {
        var copy: ([String: Any]) -> (OSStatus, CFTypeRef?) = { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }
        var add: ([String: Any]) -> OSStatus = { SecItemAdd($0 as CFDictionary, nil) }
        var update: ([String: Any], [String: Any]) -> OSStatus = { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) }
        var delete: ([String: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
    }

    private let service: String
    private let keychain: Keychain

    public convenience init(service: String = "dev.codipad.extension-secrets") {
        self.init(service: service, keychain: Keychain())
    }

    internal init(service: String, keychain: Keychain) {
        self.service = service
        self.keychain = keychain
    }

    /// JSON contract: get returns a string or null, keys returns strings, writes return null.
    public func perform(_ method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "secrets.get":
            var query = baseQuery(key: try string(params, "key"))
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = keychain.copy(query)
            if status == errSecItemNotFound { return NSNull() }
            try check(status)
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw failure("KeychainCorrupt", "credential data is not UTF-8")
            }
            return value
        case "secrets.set":
            let key = try string(params, "key")
            let data = Data(try string(params, "value").utf8)
            let query = baseQuery(key: key)
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = keychain.add(item)
            if status == errSecDuplicateItem {
                try check(keychain.update(query, [kSecValueData as String: data]))
            } else {
                try check(status)
            }
            return NSNull()
        case "secrets.delete":
            let status = keychain.delete(baseQuery(key: try string(params, "key")))
            if status != errSecItemNotFound { try check(status) }
            return NSNull()
        case "secrets.keys":
            var query = baseQuery()
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            let (status, result) = keychain.copy(query)
            if status == errSecItemNotFound { return [String]() }
            try check(status)
            guard let items = result as? [[String: Any]] else {
                throw failure("KeychainCorrupt", "credential attributes are invalid")
            }
            return try items.map { item in
                guard let key = item[kSecAttrAccount as String] as? String else {
                    throw failure("KeychainCorrupt", "credential account is invalid")
                }
                return key
            }.sorted()
        default:
            throw failure("InvalidRequest", "unknown secret operation")
        }
    }

    private func baseQuery(key: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if let key { query[kSecAttrAccount as String] = key }
        return query
    }

    private func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String else {
            throw failure("InvalidRequest", "secret operation requires string parameters")
        }
        return value
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw WorkspaceSecretStoreError(code: "KeychainUnavailable",
                                            message: "Keychain operation failed (status \(status))", status: status)
        }
    }

    private func failure(_ code: String, _ message: String) -> WorkspaceSecretStoreError {
        WorkspaceSecretStoreError(code: code, message: message, status: nil)
    }
}
