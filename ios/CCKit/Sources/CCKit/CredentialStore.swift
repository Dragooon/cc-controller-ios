import Foundation
import LocalAuthentication

public enum CredentialStoreError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case accessDenied
    case biometric(LAError.Code)
    case invalidData
    case system(String)
    case systemStatus(Int32, String)

    public var statusCode: Int32? {
        guard case .systemStatus(let status, _) = self else { return nil }
        return status
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Secure storage is unavailable on this device."
        case .accessDenied: "Secure storage could not be unlocked."
        case .biometric: "Face ID did not work. Try again."
        case .invalidData: "Secure storage contained invalid data."
        case .system(let message): message
        case .systemStatus(_, let message): message
        }
    }
}

public protocol CredentialStore: Sendable {
    func getDeviceToken() async throws -> String?
    func setDeviceToken(_ value: String) async throws
    func deleteDeviceToken() async throws
    func getNativeSecret() async throws -> String?
    func hasNativeSecret() async throws -> Bool
    func setNativeSecret(_ value: String) async throws
    func deleteNativeSecret() async throws
}

public extension CredentialStore {
    func loadDeviceToken() async throws -> String? { try await getDeviceToken() }
    func saveDeviceToken(_ value: String) async throws { try await setDeviceToken(value) }
    func loadNativeSecret() async throws -> String? { try await getNativeSecret() }
    func saveNativeSecret(_ value: String) async throws { try await setNativeSecret(value) }
    func deleteAll() async throws {
        try await deleteDeviceToken()
        try await deleteNativeSecret()
    }
}

public actor InMemoryCredentialStore: CredentialStore {
    private var storedDeviceToken: String?
    private var storedNativeSecret: String?

    public init(deviceToken: String? = nil, nativeSecret: String? = nil) {
        storedDeviceToken = deviceToken
        storedNativeSecret = nativeSecret
    }

    public func getDeviceToken() async throws -> String? { storedDeviceToken }
    public func setDeviceToken(_ value: String) async throws { storedDeviceToken = value }
    public func deleteDeviceToken() async throws { storedDeviceToken = nil }
    public func getNativeSecret() async throws -> String? { storedNativeSecret }
    public func hasNativeSecret() async throws -> Bool { storedNativeSecret != nil }
    public func setNativeSecret(_ value: String) async throws { storedNativeSecret = value }
    public func deleteNativeSecret() async throws { storedNativeSecret = nil }
}

#if os(iOS)
import LocalAuthentication
import Security

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.cc-controller.native-auth", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func getDeviceToken() async throws -> String? {
        try read(account: "deviceToken", context: nil)
    }

    public func setDeviceToken(_ value: String) async throws {
        try write(value, account: "deviceToken", access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, control: nil)
    }

    public func deleteDeviceToken() async throws {
        try remove(account: "deviceToken")
    }

    public func getNativeSecret() async throws -> String? {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock cc-controller")
        } catch let error as LAError {
            throw CredentialStoreError.biometric(error.code)
        } catch {
            throw CredentialStoreError.system(error.localizedDescription)
        }
        return try read(account: "nativeSecret", context: context)
    }

    public func hasNativeSecret() async throws -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: "nativeSecret")
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = false
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed: return true
        case errSecItemNotFound: return false
        default: throw CredentialStoreError.systemStatus(status, SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }

    public func setNativeSecret(_ value: String) async throws {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw CredentialStoreError.system((error?.takeRetainedValue() as Error?)?.localizedDescription ?? "Could not create secure storage policy.")
        }
        try write(value, account: "nativeSecret", access: nil, control: control)
    }

    public func deleteNativeSecret() async throws {
        try remove(account: "nativeSecret")
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func read(account: String, context: LAContext?) throws -> String? {
        var query = baseQuery(account: account)
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw CredentialStoreError.invalidData }
            return value
        case errSecItemNotFound: return nil
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled: throw CredentialStoreError.accessDenied
        default: throw CredentialStoreError.systemStatus(status, SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }

    private func write(_ value: String, account: String, access: CFString?, control: SecAccessControl?) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        if let access { query[kSecAttrAccessible as String] = access }
        if let control { query[kSecAttrAccessControl as String] = control }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var match = baseQuery(account: account)
            match.removeValue(forKey: kSecReturnData as String)
            let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            let updateStatus = SecItemUpdate(match as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw CredentialStoreError.systemStatus(updateStatus, "Keychain update failed (\(updateStatus)).") }
        } else if status != errSecSuccess {
            throw CredentialStoreError.systemStatus(status, "Keychain write failed (\(status)).")
        }
    }

    private func remove(account: String) throws {
        var query = baseQuery(account: account)
        query.removeValue(forKey: kSecReturnData as String)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.systemStatus(status, "Keychain delete failed (\(status)).") }
    }
}
#endif
