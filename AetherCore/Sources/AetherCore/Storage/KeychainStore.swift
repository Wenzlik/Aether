import Foundation
import Security

/// Lightweight Keychain wrapper for tokens and small secrets.
///
/// Backed by `kSecClassGenericPassword`. One instance per service identifier;
/// every entry is keyed by an arbitrary string and namespaced under the
/// service. Sync-only — nothing here goes to iCloud Keychain unless we
/// explicitly opt in later.
public actor KeychainStore {
    private let service: String

    public init(service: String = "cz.zmrhal.aether") {
        self.service = service
    }

    // MARK: - String convenience

    public func setString(_ value: String?, for key: String) throws {
        try setData(value.map { Data($0.utf8) }, for: key)
    }

    public func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Data primitives

    public func setData(_ value: Data?, for key: String) throws {
        // Delete first so we don't accidentally append duplicates; Keychain's
        // SecItemUpdate has odd corner cases with this query shape.
        SecItemDelete(baseQuery(for: key) as CFDictionary)

        guard let value else { return }

        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status)
        }
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.osStatus(status)
        }
    }

    public func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.osStatus(status)
        }
    }

    /// Wipe everything this service owns. Used on sign-out flows.
    public func removeAll() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.osStatus(status)
        }
    }

    // MARK: - Helpers

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

public enum KeychainStoreError: Error, Sendable, Equatable {
    case osStatus(OSStatus)
}
