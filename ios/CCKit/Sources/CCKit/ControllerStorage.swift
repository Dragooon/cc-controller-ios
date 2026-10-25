import Foundation

public enum ControllerStorage {
    public static let legacyRelayEndpointsKey = "CCRelayEndpoints"

    public static func cacheDirectory(root: URL, controllerID: ControllerID) -> URL {
        root.appendingPathComponent(controllerID.rawValue, isDirectory: true)
    }

    public static func namespacedKey(_ key: String, controllerID: ControllerID) -> String {
        ControllerNamespace(controllerID).key(key)
    }

    public static func defaultCacheRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc-controller", isDirectory: true)
    }
}

public enum ControllerMigrationError: Error, Sendable, Equatable, LocalizedError {
    case simulatedCrash(ControllerMigration.CrashPoint)

    public var errorDescription: String? {
        switch self {
        case .simulatedCrash(let point): "Simulated migration crash at \(point)."
        }
    }
}

public enum ControllerMigration {
    public enum CrashPoint: Sendable, Equatable {
        case afterCacheStaged
        case afterCacheMoved
        case afterCacheEntryMoved
        case afterSettingsMoved
        case afterCredentialsMoved
    }

    @MainActor
    public static func migrate(
        legacyCredentials: any CredentialStore,
        macCredentials: any CredentialStore,
        legacyCacheDirectory: URL,
        macCacheDirectory: URL,
        defaults: UserDefaults = .standard,
        crashAfter: CrashPoint? = nil
    ) async throws {
        try migrateLegacyCacheAndSettings(
            legacyCacheDirectory: legacyCacheDirectory,
            macCacheDirectory: macCacheDirectory,
            defaults: defaults,
            crashAfter: crashAfter
        )
        if crashAfter == .afterSettingsMoved { throw ControllerMigrationError.simulatedCrash(.afterSettingsMoved) }
        try await moveCredentials(legacy: legacyCredentials, current: macCredentials)
        if crashAfter == .afterCredentialsMoved { throw ControllerMigrationError.simulatedCrash(.afterCredentialsMoved) }
    }

    /// Performs the non-biometric part of migration synchronously before the app constructs its stores.
    @MainActor
    public static func migrateLegacyCacheAndSettings(
        legacyCacheDirectory: URL,
        macCacheDirectory: URL,
        defaults: UserDefaults = .standard,
        crashAfter: CrashPoint? = nil,
        fileManager: FileManager = .default
    ) throws {
        try recoverOrMoveCache(
            legacyCacheDirectory: legacyCacheDirectory,
            macCacheDirectory: macCacheDirectory,
            crashAfter: crashAfter,
            fileManager: fileManager
        )
        if crashAfter == .afterCacheStaged || crashAfter == .afterCacheMoved || crashAfter == .afterCacheEntryMoved {
            throw ControllerMigrationError.simulatedCrash(crashAfter!)
        }
        moveConnectionSettings(defaults: defaults)
        if crashAfter == .afterSettingsMoved {
            throw ControllerMigrationError.simulatedCrash(.afterSettingsMoved)
        }
    }

    private static func moveCredentials(
        legacy: any CredentialStore,
        current: any CredentialStore
    ) async throws {
        try await move(
            read: { try await legacy.getDeviceToken() },
            write: { try await current.setDeviceToken($0) },
            delete: { try await legacy.deleteDeviceToken() },
            current: { try await current.getDeviceToken() }
        )
        try await move(
            read: { try await legacy.getNativeSecret() },
            write: { try await current.setNativeSecret($0) },
            delete: { try await legacy.deleteNativeSecret() },
            current: { try await current.getNativeSecret() }
        )
        try await move(
            read: { try await legacy.getRelayPin() },
            write: { try await current.setRelayPin($0) },
            delete: { try await legacy.deleteRelayPin() },
            current: { try await current.getRelayPin() }
        )
    }

    private static func move(
        read: () async throws -> String?,
        write: (String) async throws -> Void,
        delete: () async throws -> Void,
        current: () async throws -> String?
    ) async throws {
        if try await current() != nil {
            try await delete()
            return
        }
        guard let value = try await read() else { return }
        try await write(value)
        try await delete()
    }

    private static func moveConnectionSettings(defaults: UserDefaults) {
        let macKey = ControllerStorage.namespacedKey(
            ControllerStorage.legacyRelayEndpointsKey,
            controllerID: .mac
        )
        if defaults.object(forKey: macKey) == nil,
           let value = defaults.object(forKey: ControllerStorage.legacyRelayEndpointsKey) {
            defaults.set(value, forKey: macKey)
        }
        defaults.removeObject(forKey: ControllerStorage.legacyRelayEndpointsKey)
    }

    private static func recoverOrMoveCache(
        legacyCacheDirectory: URL,
        macCacheDirectory: URL,
        crashAfter: CrashPoint?,
        fileManager: FileManager
    ) throws {
        guard legacyCacheDirectory.standardizedFileURL != macCacheDirectory.standardizedFileURL else { return }
        let staging = legacyCacheDirectory.appendingPathExtension("migration")
        let targetExists = fileManager.fileExists(atPath: macCacheDirectory.path)
        let stagingExists = fileManager.fileExists(atPath: staging.path)

        if !targetExists, stagingExists {
            try fileManager.createDirectory(at: macCacheDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: macCacheDirectory)
            return
        }

        guard fileManager.fileExists(atPath: legacyCacheDirectory.path) else { return }
        let sourceIsParent = macCacheDirectory.deletingLastPathComponent().standardizedFileURL == legacyCacheDirectory.standardizedFileURL
        let hasLegacyPayload = legacyPayloadExists(
            at: legacyCacheDirectory,
            excluding: sourceIsParent ? [macCacheDirectory.lastPathComponent, staging.lastPathComponent] : [],
            fileManager: fileManager
        )
        guard hasLegacyPayload else { return }

        if sourceIsParent {
            try fileManager.createDirectory(at: macCacheDirectory, withIntermediateDirectories: true)
            let names = try fileManager.contentsOfDirectory(atPath: legacyCacheDirectory.path).sorted()
            for name in names where name != macCacheDirectory.lastPathComponent && name != staging.lastPathComponent {
                let source = legacyCacheDirectory.appendingPathComponent(name)
                let destination = macCacheDirectory.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.moveItem(at: source, to: destination)
                } else {
                    try fileManager.removeItem(at: source)
                }
                if crashAfter == .afterCacheEntryMoved { return }
            }
            return
        }

        if !targetExists {
            try fileManager.moveItem(at: legacyCacheDirectory, to: staging)
            if crashAfter == .afterCacheStaged { return }
            try fileManager.moveItem(at: staging, to: macCacheDirectory)
            return
        }

        try fileManager.createDirectory(at: macCacheDirectory, withIntermediateDirectories: true)
        let names = try fileManager.contentsOfDirectory(atPath: legacyCacheDirectory.path)
        for name in names where name != macCacheDirectory.lastPathComponent && name != staging.lastPathComponent {
            let source = legacyCacheDirectory.appendingPathComponent(name)
            let destination = macCacheDirectory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: source, to: destination)
            } else {
                try fileManager.removeItem(at: source)
            }
        }
    }

    private static func legacyPayloadExists(
        at directory: URL,
        excluding names: [String],
        fileManager: FileManager
    ) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
        return entries.contains { !names.contains($0) }
    }
}
