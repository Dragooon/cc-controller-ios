import Foundation

@MainActor
public final class ControllerRegistry {
    public static let defaultDefaultsKey = "CCControllerRegistry"

    public private(set) var controllers: [ControllerConfig]
    public var configs: [ControllerConfig] { controllers }

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let cacheRoot: URL?
    private let credentialStore: ((ControllerID) -> any CredentialStore)?

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = ControllerRegistry.defaultDefaultsKey,
        seed: ControllerConfig? = nil,
        cacheRoot: URL? = nil,
        credentialStore: ((ControllerID) -> any CredentialStore)? = nil
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.cacheRoot = cacheRoot
        self.credentialStore = credentialStore
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([ControllerConfig].self, from: data),
           !saved.isEmpty {
            controllers = saved
        } else {
            controllers = [seed ?? .mac()]
            persist()
        }
    }

    @discardableResult
    public func add(_ config: ControllerConfig) -> Bool {
        guard !controllers.contains(where: { $0.id == config.id }) else { return false }
        controllers.append(config)
        persist()
        return true
    }

    public func remove(_ id: ControllerID) async {
        guard let index = controllers.firstIndex(where: { $0.id == id }) else { return }
        if let credentialStore {
            try? await credentialStore(id).deleteAll()
        }
        if let cacheRoot {
            let directory = ControllerStorage.cacheDirectory(root: cacheRoot, controllerID: id)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.removeObject(forKey: ControllerStorage.namespacedKey(
            ControllerStorage.legacyRelayEndpointsKey,
            controllerID: id
        ))
        controllers.remove(at: index)
        persist()
    }

    public func reorder(_ ids: [ControllerID]) {
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        controllers.sort { left, right in
            (positions[left.id] ?? ids.count) < (positions[right.id] ?? ids.count)
        }
        persist()
    }

    public func move(fromOffsets offsets: IndexSet, toOffset offset: Int) {
        var moved = controllers
        let values = offsets.sorted().reversed().map { moved.remove(at: $0) }.reversed()
        let insertion = min(max(0, offset), moved.count)
        moved.insert(contentsOf: values, at: insertion)
        controllers = moved
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(controllers) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
