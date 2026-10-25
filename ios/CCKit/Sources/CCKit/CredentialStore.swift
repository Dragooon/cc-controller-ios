import Foundation
import LocalAuthentication

public enum CredentialStoreError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case accessDenied
    case biometric(LAError.Code)
    case keychain(Int32)
    case invalidData
    case system(String)
    case systemStatus(Int32, String)

    public var statusCode: Int32? {
        switch self {
        case .keychain(let status), .systemStatus(let status, _): status
        default: nil
        }
    }

    public var diagnosticCode: String? {
        switch self {
        case .biometric(let code): "LAError \(code.rawValue)"
        case .keychain(let status), .systemStatus(let status, _): "OSStatus \(status)"
        default: nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Secure storage is unavailable on this device."
        case .accessDenied: "Secure storage could not be unlocked."
        case .biometric(let code): "Face ID did not work. Try again. (LAError \(code.rawValue))"
        case .keychain(let status): "Secure storage could not be unlocked. (OSStatus \(status))"
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
    func getRelayPin() async throws -> String?
    func setRelayPin(_ value: String) async throws
    func deleteRelayPin() async throws
}

public extension CredentialStore {
    func getRelayPin() async throws -> String? { nil }
    func setRelayPin(_ value: String) async throws { throw CredentialStoreError.unavailable }
    func deleteRelayPin() async throws { }
}

public extension CredentialStore {
    func loadDeviceToken() async throws -> String? { try await getDeviceToken() }
    func saveDeviceToken(_ value: String) async throws { try await setDeviceToken(value) }
    func loadNativeSecret() async throws -> String? { try await getNativeSecret() }
    func saveNativeSecret(_ value: String) async throws { try await setNativeSecret(value) }
    func loadRelayPin() async throws -> String? { try await getRelayPin() }
    func saveRelayPin(_ value: String) async throws { try await setRelayPin(value) }
    func deleteAll() async throws {
        try await deleteDeviceToken()
        try await deleteNativeSecret()
        try await deleteRelayPin()
    }
}

public actor InMemoryCredentialStore: CredentialStore {
    public let controllerID: ControllerID?
    private var storedDeviceToken: String?
    private var storedNativeSecret: String?
    private var storedRelayPin: String?

    public init(
        controllerID: ControllerID? = nil,
        deviceToken: String? = nil,
        nativeSecret: String? = nil,
        relayPin: String? = nil
    ) {
        self.controllerID = controllerID
        storedDeviceToken = deviceToken
        storedNativeSecret = nativeSecret
        storedRelayPin = relayPin
    }

    public func getDeviceToken() async throws -> String? { storedDeviceToken }
    public func setDeviceToken(_ value: String) async throws { storedDeviceToken = value }
    public func deleteDeviceToken() async throws { storedDeviceToken = nil }
    public func getNativeSecret() async throws -> String? { storedNativeSecret }
    public func hasNativeSecret() async throws -> Bool { storedNativeSecret != nil }
    public func setNativeSecret(_ value: String) async throws { storedNativeSecret = value }
    public func deleteNativeSecret() async throws { storedNativeSecret = nil }
    public func getRelayPin() async throws -> String? { storedRelayPin }
    public func setRelayPin(_ value: String) async throws { storedRelayPin = value }
    public func deleteRelayPin() async throws { storedRelayPin = nil }
}

#if os(iOS)
import LocalAuthentication
import OSLog
import Security

private let credentialMigrationLogger = Logger(
    subsystem: "com.example.cc-controller",
    category: "credential-migration"
)

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public let controllerID: ControllerID?
    private let service: String
    private let accessGroup: String?

    public init(
        service: String = "com.cc-controller.native-auth",
        accessGroup: String? = nil,
        controllerID: ControllerID? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.controllerID = controllerID
    }

    public func getDeviceToken() async throws -> String? {
        try read(account: account("deviceToken"), context: nil)
    }

    public func setDeviceToken(_ value: String) async throws {
        try write(value, account: account("deviceToken"), access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, control: nil)
    }

    public func deleteDeviceToken() async throws {
        try remove(account: account("deviceToken"))
    }

    public func getRelayPin() async throws -> String? {
        guard let value = try read(account: account("relayPin"), context: nil) else { return nil }
        guard (try? RelayPin(value)) != nil else { throw CredentialStoreError.invalidData }
        return value
    }

    public func setRelayPin(_ value: String) async throws {
        guard (try? RelayPin(value)) != nil else { throw CredentialStoreError.invalidData }
        try write(value, account: account("relayPin"), access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, control: nil)
    }

    public func deleteRelayPin() async throws {
        try remove(account: account("relayPin"))
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
        return try read(account: account("nativeSecret"), context: context)
    }

    public func hasNativeSecret() async throws -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account("nativeSecret"))
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
        try write(value, account: account("nativeSecret"), access: nil, control: control)
    }

    public func deleteNativeSecret() async throws {
        try remove(account: account("nativeSecret"))
    }

    private func account(_ name: String) -> String {
        controllerID.map { "\(name).\($0.rawValue)" } ?? name
    }

    /// Rekeys the legacy items without reading the biometric-protected secret.
    public func moveLegacyItems(to destination: KeychainCredentialStore) throws {
        guard service == destination.service, accessGroup == destination.accessGroup else {
            throw CredentialStoreError.system("Credential stores must use the same Keychain service and access group.")
        }
        for name in ["deviceToken", "nativeSecret", "relayPin"] {
            let oldAccount = account(name)
            let newAccount = destination.account(name)
            let context = LAContext()
            context.interactionNotAllowed = true
            var oldQuery = baseQuery(account: oldAccount)
            oldQuery.removeValue(forKey: kSecReturnData as String)
            oldQuery[kSecUseAuthenticationContext as String] = context
            var destinationQuery = destination.baseQuery(account: newAccount)
            destinationQuery[kSecReturnData as String] = false
            destinationQuery[kSecUseAuthenticationContext as String] = context
            let destinationStatus = SecItemCopyMatching(destinationQuery as CFDictionary, nil)
            if destinationStatus == errSecSuccess || destinationStatus == errSecInteractionNotAllowed {
                try remove(account: oldAccount)
                continue
            }
            guard destinationStatus == errSecItemNotFound else {
                throw CredentialStoreError.systemStatus(destinationStatus, "Keychain lookup failed (\(destinationStatus)).")
            }
            let status = SecItemUpdate(oldQuery as CFDictionary, [kSecAttrAccount as String: newAccount] as CFDictionary)
            if status == errSecInteractionNotAllowed, name == "nativeSecret" {
                // Keep the legacy biometric item so the next launch can retry without losing the pairing.
                credentialMigrationLogger.error("Native secret migration requires interaction; retaining legacy Keychain item.")
                continue
            }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.systemStatus(status, "Keychain migration failed (\(status)).")
            }
        }
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
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled: throw CredentialStoreError.keychain(status)
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
