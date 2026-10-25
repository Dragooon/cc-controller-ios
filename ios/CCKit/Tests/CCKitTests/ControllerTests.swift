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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private extension RelayPin {
    static var testValue: String { "41B9C42AC34D8CD7F63491C59B8405AE5AA7B6A3015C5367E951E836AFD65294" }
}
