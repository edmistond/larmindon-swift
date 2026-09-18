import Foundation
import Security

public protocol ProviderCredentialStore: Sendable {
    func hasCredential(for provider: ServerProviderID) -> Bool
    func credential(for provider: ServerProviderID) throws -> String?
    func saveCredential(_ credential: String, for provider: ServerProviderID) throws
    func removeCredential(for provider: ServerProviderID) throws
}

public struct KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service = "com.davidedmiston.larmindon.provider-credentials"

    public init() {}

    public func hasCredential(for provider: ServerProviderID) -> Bool {
        (try? credential(for: provider))?.isEmpty == false
    }

    public func credential(for provider: ServerProviderID) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
            let data = result as? Data,
            let credential = String(data: data, encoding: .utf8)
        else {
            throw ProviderCredentialError.keychain(status)
        }
        return credential
    }

    public func saveCredential(
        _ credential: String,
        for provider: ServerProviderID
    ) throws {
        let cleaned = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ProviderCredentialError.emptyCredential
        }
        let data = Data(cleaned.utf8)
        let query = baseQuery(for: provider)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderCredentialError.keychain(updateStatus)
        }

        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProviderCredentialError.keychain(addStatus)
        }
    }

    public func removeCredential(for provider: ServerProviderID) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialError.keychain(status)
        }
    }

    private func baseQuery(for provider: ServerProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

public enum ProviderCredentialError: LocalizedError, Equatable {
    case emptyCredential
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyCredential:
            return "Enter an API key before saving."
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "Keychain operation failed with status \(status)."
        }
    }
}
