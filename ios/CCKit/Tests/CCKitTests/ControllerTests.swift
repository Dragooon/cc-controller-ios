import Foundation
import XCTest
@testable import CCKit

@MainActor
final class ControllerTests: XCTestCase {
    func testControllerInfoDecodesKnownAndUnknownValues() throws {
        let data = Data("""
        {"controller":{"id":"mustafar","name":"Mustafar","kind":"stockade","capabilities":["list","transcript","future_action"]}}
        """.utf8)
        let bootstrap = try JSONDecoder.ccKit().decode(Bootstrap.self, from: data)
        let info = try XCTUnwrap(bootstrap.controller)
        XCTAssertEqual(info.id, try ControllerID("mustafar"))
        XCTAssertEqual(info.name, "Mustafar")
        XCTAssertEqual(info.kind, .stockade)
        XCTAssertEqual(info.capabilities, [.list, .transcript, .unknown("future_action")])
    }

    func testControllerInfoAbsentUsesConfiguredFallbackOnAppStore() throws {
        let bootstrap = try JSONDecoder.ccKit().decode(Bootstrap.self, from: Data("{\"apiVersion\":2}".utf8))
        XCTAssertNil(bootstrap.controller)
        let fallback = ControllerInfo(id: try ControllerID("mustafar"), name: "Mustafar", kind: .claudeCode, capabilities: ControllerCapability.all)
        let store = AppStore(
            client: APIClient(baseURL: URL(string: "http://127.0.0.1:47832")!),
            bearerProvider: { "fixture" },
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            controllerInfo: fallback
        )
        XCTAssertEqual(store.controllerInfo, fallback)
    }

    func testRegistryDecodesSavedEntriesWithLegacyRelayHostID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(Data("""
        [{"id":"mustafar","displayName":"Mustafar","directBaseURL":null,"relayEndpoints":[],"relayHostID":"mustafar"}]
        """.utf8), forKey: ControllerRegistry.defaultDefaultsKey)

        let registry = ControllerRegistry(defaults: defaults)

        XCTAssertEqual(registry.controllers, [ControllerConfig(id: try ControllerID("mustafar"), displayName: "Mustafar")])
    }

    func testControllerNamespacesDoNotCollide() throws {
        let mac = try ControllerID("mac")
        let mustafar = try ControllerID("mustafar")
        XCTAssertEqual(ControllerStorage.namespacedKey("CCRelayEndpoints", controllerID: mac), "CCController.mac.CCRelayEndpoints")
        let root = temporaryDirectory()
        XCTAssertNotEqual(
            ControllerStorage.cacheDirectory(root: root, controllerID: mac),
            ControllerStorage.cacheDirectory(root: root, controllerID: mustafar)
        )
        XCTAssertThrowsError(try ControllerID("UpperCase"))
        XCTAssertThrowsError(try ControllerID(String(repeating: "a", count: 33)))
    }

    func testMigrationMovesRealNestedCacheLayoutAndIsIdempotent() async throws {
        let root = temporaryDirectory()
        let legacy = root.appendingPathComponent("cc-controller")
        let mac = legacy.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for name in ["state.json", "drafts.json", "queued-notes.json", "transcript-c2Vzc2lvbg.json"] {
            try Data(name.utf8).write(to: legacy.appendingPathComponent(name))
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let old = InMemoryCredentialStore()
        let current = InMemoryCredentialStore(controllerID: .mac)

        try await ControllerMigration.migrate(
            legacyCredentials: old,
            macCredentials: current,
            legacyCacheDirectory: legacy,
            macCacheDirectory: mac,
            defaults: defaults
        )
        let namesAfterMove = try FileManager.default.contentsOfDirectory(atPath: legacy.path)
        XCTAssertEqual(namesAfterMove, ["mac"])
        for name in ["state.json", "drafts.json", "queued-notes.json", "transcript-c2Vzc2lvbg.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: mac.appendingPathComponent(name).path))
        }

        try await ControllerMigration.migrate(
            legacyCredentials: old,
            macCredentials: current,
            legacyCacheDirectory: legacy,
            macCacheDirectory: mac,
            defaults: defaults
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.path), ["mac"])
    }

    func testNestedCacheMigrationRecoversAfterEntryCrash() async throws {
        let root = temporaryDirectory()
        let legacy = root.appendingPathComponent("cc-controller")
        let mac = legacy.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let names = ["state.json", "drafts.json", "queued-notes.json", "transcript-c2Vzc2lvbg.json"]
        for name in names {
            try Data(name.utf8).write(to: legacy.appendingPathComponent(name))
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let old = InMemoryCredentialStore()
        let current = InMemoryCredentialStore(controllerID: .mac)

        do {
            try await ControllerMigration.migrate(
                legacyCredentials: old,
                macCredentials: current,
                legacyCacheDirectory: legacy,
                macCacheDirectory: mac,
                defaults: defaults,
                crashAfter: .afterCacheEntryMoved
            )
            XCTFail("Expected simulated crash")
        } catch ControllerMigrationError.simulatedCrash(.afterCacheEntryMoved) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: mac.path))
            XCTAssertLessThan(try FileManager.default.contentsOfDirectory(atPath: legacy.path).count, names.count + 1)
        }

        try await ControllerMigration.migrate(
            legacyCredentials: old,
            macCredentials: current,
            legacyCacheDirectory: legacy,
            macCacheDirectory: mac,
            defaults: defaults
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.path), ["mac"])
        for name in names {
            XCTAssertTrue(FileManager.default.fileExists(atPath: mac.appendingPathComponent(name).path))
        }
    }

    func testMigrationMovesCredentialsCacheAndSettingsAndIsIdempotent() async throws {
        let root = temporaryDirectory()
        let legacy = root.appendingPathComponent("legacy")
        let mac = root.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: legacy.appendingPathComponent("state.json"))
        try Data("drafts".utf8).write(to: legacy.appendingPathComponent("drafts.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("https://127.0.0.1:47833", forKey: ControllerStorage.legacyRelayEndpointsKey)
        let old = InMemoryCredentialStore(deviceToken: "device", nativeSecret: "secret", relayPin: RelayPin.testValue)
        let current = InMemoryCredentialStore(controllerID: .mac)

        try await ControllerMigration.migrate(
            legacyCredentials: old,
            macCredentials: current,
            legacyCacheDirectory: legacy,
            macCacheDirectory: mac,
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac.appendingPathComponent("state.json").path))
        XCTAssertEqual(defaults.string(forKey: ControllerStorage.namespacedKey("CCRelayEndpoints", controllerID: .mac)), "https://127.0.0.1:47833")
        XCTAssertNil(defaults.string(forKey: ControllerStorage.legacyRelayEndpointsKey))
        let currentDevice = try await current.getDeviceToken()
        let currentSecret = try await current.getNativeSecret()
        let oldDevice = try await old.getDeviceToken()
        XCTAssertEqual(currentDevice, "device")
        XCTAssertEqual(currentSecret, "secret")
        XCTAssertNil(oldDevice)

        try await ControllerMigration.migrate(
            legacyCredentials: old,
            macCredentials: current,
            legacyCacheDirectory: legacy,
            macCacheDirectory: mac,
            defaults: defaults
        )
        let reloadedSecret = try await current.getNativeSecret()
        XCTAssertEqual(reloadedSecret, "secret")
        XCTAssertNil(defaults.string(forKey: ControllerStorage.legacyRelayEndpointsKey))
    }

    func testMigrationRecoversAfterSimulatedCrashBetweenCacheSteps() async throws {
        let root = temporaryDirectory()
        let legacy = root.appendingPathComponent("legacy")
        let mac = root.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: legacy.appendingPathComponent("state.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let old = InMemoryCredentialStore(deviceToken: "device")
        let current = InMemoryCredentialStore(controllerID: .mac)

        do {
            try await ControllerMigration.migrate(
                legacyCredentials: old,
                macCredentials: current,
                legacyCacheDirectory: legacy,
                macCacheDirectory: mac,
                defaults: defaults,
                crashAfter: .afterCacheStaged
            )
            XCTFail("Expected simulated crash")
        } catch ControllerMigrationError.simulatedCrash(.afterCacheStaged) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: mac.path))
        }

        try await ControllerMigration.migrate(
            legacyCredentials: old,
            macCredentials: current,
            legacyCacheDirectory: legacy,
            macCacheDirectory: mac,
            defaults: defaults
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac.appendingPathComponent("state.json").path))
        let currentDevice = try await current.getDeviceToken()
        let oldDevice = try await old.getDeviceToken()
        XCTAssertEqual(currentDevice, "device")
        XCTAssertNil(oldDevice)
    }

    func testRegistryRemoveDeletesOnlyThatControllerAndReloadsOrder() async throws {
        let root = temporaryDirectory()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let first = try ControllerID("first")
        let second = try ControllerID("second")
        let firstStore = InMemoryCredentialStore(controllerID: first, deviceToken: "first")
        let secondStore = InMemoryCredentialStore(controllerID: second, deviceToken: "second")
        var stores: [ControllerID: InMemoryCredentialStore] = [first: firstStore, second: secondStore]
        let firstDirectory = ControllerStorage.cacheDirectory(root: root, controllerID: first)
        let secondDirectory = ControllerStorage.cacheDirectory(root: root, controllerID: second)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstDirectory.appendingPathComponent("state.json"))
        try Data("second".utf8).write(to: secondDirectory.appendingPathComponent("state.json"))

        let registry = ControllerRegistry(
            defaults: defaults,
            seed: ControllerConfig(id: first, displayName: "First"),
            cacheRoot: root,
            credentialStore: { id in stores[id]! }
        )
        XCTAssertTrue(registry.add(ControllerConfig(id: second, displayName: "Second")))
        registry.reorder([second, first])
        XCTAssertEqual(registry.controllers.map(\.id), [second, first])
        await registry.remove(first)
        XCTAssertEqual(registry.controllers.map(\.id), [second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDirectory.path))
        let firstDevice = try await firstStore.getDeviceToken()
        let secondDevice = try await secondStore.getDeviceToken()
        XCTAssertNil(firstDevice)
        XCTAssertEqual(secondDevice, "second")

        let reloaded = ControllerRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.controllers.map(\.id), [second])
        stores.removeAll()
    }

    func testSessionRefParsesPrimaryAndQualifiedArguments() throws {
        let primary = try ControllerID("mac")
        let qualified = try ControllerID("mustafar")

        XCTAssertEqual(
            SessionRef.parse("session-1", primaryControllerID: primary),
            SessionRef(controllerID: primary, sessionID: "session-1")
        )
        XCTAssertEqual(
            SessionRef.parse("mustafar:session-2", primaryControllerID: primary),
            SessionRef(controllerID: qualified, sessionID: "session-2")
        )
        XCTAssertNil(SessionRef.parse("mustafar:", primaryControllerID: primary))
    }

    func testRegistrySavedEntryWinsOverSeedAndLaunchOverrideIsNotPersisted() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let savedURL = URL(string: "http://saved.example")!
        let overrideURL = URL(string: "http://override.example")!
        let saved = ControllerConfig(id: .mac, displayName: "Saved", directBaseURL: savedURL)
        defaults.set(try JSONEncoder().encode([saved]), forKey: ControllerRegistry.defaultDefaultsKey)

        let registry = ControllerRegistry(
            defaults: defaults,
            seed: ControllerConfig.mac(directBaseURL: URL(string: "http://seed.example")!)
        )
        XCTAssertEqual(registry.controllers[0], saved)

        var launchOverride = registry.controllers[0]
        launchOverride.directBaseURL = overrideURL
        XCTAssertTrue(registry.update(launchOverride, persist: false))
        XCTAssertEqual(registry.controllers[0].directBaseURL, overrideURL)
        XCTAssertEqual(ControllerRegistry(defaults: defaults).controllers[0], saved)
    }

    func testResolveMacMigratesValidLegacyRelayEndpointsAndRequestsPersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let legacyKey = ControllerStorage.namespacedKey(ControllerStorage.legacyRelayEndpointsKey, controllerID: .mac)
        let saved = ControllerConfig.mac()
        let endpoint = URL(string: "https://192.0.2.1:47833")!
        defaults.set("invalid https://192.0.2.1:47833 https://192.0.2.2:47833", forKey: legacyKey)
        let registry = ControllerRegistry(defaults: defaults, seed: saved)

        let resolution = ControllerConfig.resolveMac(
            saved: registry.controllers[0],
            legacyRelayEndpoints: defaults.string(forKey: legacyKey),
            bundleDefaultEndpoints: [],
            hasLaunchOverride: false
        )
        if resolution.shouldPersist { _ = registry.update(resolution.config) }
        if resolution.shouldRemoveLegacyRelayEndpoints { defaults.removeObject(forKey: legacyKey) }

        XCTAssertEqual(resolution.config, ControllerConfig.mac(relayEndpoints: [endpoint, URL(string: "https://192.0.2.2:47833")!]))
        XCTAssertTrue(resolution.shouldPersist)
        XCTAssertTrue(resolution.shouldRemoveLegacyRelayEndpoints)
        XCTAssertEqual(ControllerRegistry(defaults: defaults).controllers[0], resolution.config)
        XCTAssertNil(defaults.string(forKey: legacyKey))
    }

    func testResolveMacIgnoresInvalidLegacyRelayEndpointsAndRemovesKey() {
        let saved = ControllerConfig.mac()

        let resolution = ControllerConfig.resolveMac(
            saved: saved,
            legacyRelayEndpoints: "http://192.0.2.1:47833 not-an-endpoint",
            bundleDefaultEndpoints: [],
            hasLaunchOverride: false
        )

        XCTAssertEqual(resolution.config, saved)
        XCTAssertFalse(resolution.shouldPersist)
        XCTAssertTrue(resolution.shouldRemoveLegacyRelayEndpoints)
    }

    func testResolveMacUsesBundleDefaultsForLoopbackEntryWithoutPersistence() throws {
        let saved = ControllerConfig.mac(directBaseURL: URL(string: "http://localhost:47832")!)
        let bundleEndpoint = URL(string: "https://192.0.2.1:47833")!

        let resolution = ControllerConfig.resolveMac(
            saved: saved,
            legacyRelayEndpoints: nil,
            bundleDefaultEndpoints: [bundleEndpoint],
            hasLaunchOverride: false
        )

        XCTAssertEqual(resolution.config, ControllerConfig.mac(relayEndpoints: [bundleEndpoint]))
        XCTAssertFalse(resolution.shouldPersist)
        XCTAssertFalse(resolution.shouldRemoveLegacyRelayEndpoints)
    }

    func testResolveMacSavedRelayEndpointsWinOverBundleDefaults() throws {
        let savedEndpoint = URL(string: "https://192.0.2.1:47833")!
        let bundleEndpoint = URL(string: "https://192.0.2.2:47833")!
        let saved = ControllerConfig.mac(relayEndpoints: [savedEndpoint])

        let resolution = ControllerConfig.resolveMac(
            saved: saved,
            legacyRelayEndpoints: nil,
            bundleDefaultEndpoints: [bundleEndpoint],
            hasLaunchOverride: false
        )

        XCTAssertEqual(resolution.config, saved)
        XCTAssertFalse(resolution.shouldPersist)
        XCTAssertFalse(resolution.shouldRemoveLegacyRelayEndpoints)
    }

    func testResolveMacLaunchOverrideSkipsMigrationAndBundleFallback() throws {
        let saved = ControllerConfig.mac()
        let endpoint = URL(string: "https://192.0.2.1:47833")!

        let resolution = ControllerConfig.resolveMac(
            saved: saved,
            legacyRelayEndpoints: "https://192.0.2.1:47833",
            bundleDefaultEndpoints: [endpoint],
            hasLaunchOverride: true
        )

        XCTAssertEqual(resolution.config, saved)
        XCTAssertFalse(resolution.shouldPersist)
        XCTAssertFalse(resolution.shouldRemoveLegacyRelayEndpoints)
    }

    func testExtraControllersDecodeWithoutPersistingRegistryEntries() throws {
        let entries = try ControllerRegistry.extraControllers(from: """
        [{"id":"mustafar","name":"Mustafar","server":"http://127.0.0.1:47834"}]
        """)

        XCTAssertEqual(entries, [
            ControllerConfig(
                id: try ControllerID("mustafar"),
                displayName: "Mustafar",
                directBaseURL: URL(string: "http://127.0.0.1:47834")!
            )
        ])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private extension RelayPin {
    static var testValue: String { "41B9C42AC34D8CD7F63491C59B8405AE5AA7B6A3015C5367E951E836AFD65294" }
}
