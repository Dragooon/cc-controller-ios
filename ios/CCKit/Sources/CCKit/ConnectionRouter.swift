import Foundation
import Network

public struct ConnectionTarget: @unchecked Sendable {
    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }
}

public enum ConnectionRouterError: Error, Sendable, Equatable, LocalizedError {
    case noReachableEndpoint

    public var errorDescription: String? {
        "No relay endpoint is reachable."
    }
}

/// Owns the transport selected for the daemon API and event stream.
public final class ConnectionRouter: @unchecked Sendable {
    public let mode: Mode
    public private(set) var configuredEndpoints: [URL]

    public enum Mode: Sendable, Equatable {
        case direct
        case relay
    }

    private let directURL: URL?
    private let directSession: URLSession?
    private let lock = NSLock()
    private var relaySession: RelaySession?
    private var selector: RelayEndpointSelector?
    private var selected: ConnectionTarget?
    private var pathMonitor: NWPathMonitor?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        mode = .direct
        configuredEndpoints = [baseURL]
        directURL = baseURL
        directSession = session
    }

    public init(endpoints: [URL], pin: RelayPin? = nil) {
        mode = .relay
        configuredEndpoints = endpoints
        directURL = nil
        directSession = nil
        let relay = RelaySessionFactory.make(
            endpoints: endpoints,
            mode: pin.map(PinnedTrustDelegate.Mode.pinned) ?? .trustOnFirstUse
        )
        relaySession = relay
        selector = RelayEndpointSelector(endpoints: endpoints, session: relay.session, trustDelegate: relay.trustDelegate)
        startPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    public var configuredBaseURL: URL {
        directURL ?? configuredEndpoints.first ?? URL(string: "https://127.0.0.1:47833")!
    }

    public var selectedEndpoint: URL? {
        withLock { selected?.baseURL }
    }

    public var observedPin: String? {
        withLock { relaySession?.trustDelegate.observedPin }
    }

    public var hasPinMismatch: Bool {
        withLock { relaySession?.trustDelegate.lastFailure != nil }
    }

    public func target() async throws -> ConnectionTarget {
        if mode == .direct {
            return ConnectionTarget(baseURL: directURL!, session: directSession!)
        }
        if let selected = withLock({ self.selected }) {
            return selected
        }
        let selector = withLock { self.selector }
        guard let selector, let selection = await selector.select() else {
            throw ConnectionRouterError.noReachableEndpoint
        }
        return withLock {
            let target = ConnectionTarget(baseURL: selection.endpoint, session: relaySession!.session)
            selected = target
            return target
        }
    }

    public func invalidate() {
        let selector = withLock {
            selected = nil
            return self.selector
        }
        Task { await selector?.invalidate() }
    }

    public func endpointOutcomes() async -> [URL: RelayEndpointOutcome] {
        guard let selector else { return [:] }
        return await selector.outcomes()
    }

    public func trustFailure(for endpoint: URL) -> PinnedTrustDelegate.Failure? {
        withLock { relaySession?.trustDelegate.failure(for: endpoint) }
    }

    public func reconfigure(pin: RelayPin?) async {
        guard mode == .relay else { return }
        let relay = RelaySessionFactory.make(
            endpoints: configuredEndpoints,
            mode: pin.map(PinnedTrustDelegate.Mode.pinned) ?? .trustOnFirstUse
        )
        let nextSelector = RelayEndpointSelector(
            endpoints: configuredEndpoints,
            session: relay.session,
            trustDelegate: relay.trustDelegate
        )
        withLock {
            relaySession = relay
            selector = nextSelector
            selected = nil
        }
    }

    public func updateEndpoints(_ endpoints: [URL], pin: RelayPin?) async {
        guard mode == .relay else { return }
        let relay = RelaySessionFactory.make(
            endpoints: endpoints,
            mode: pin.map(PinnedTrustDelegate.Mode.pinned) ?? .trustOnFirstUse
        )
        let nextSelector = RelayEndpointSelector(endpoints: endpoints, session: relay.session, trustDelegate: relay.trustDelegate)
        withLock {
            configuredEndpoints = endpoints
            relaySession = relay
            selector = nextSelector
            selected = nil
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.invalidate()
        }
        monitor.start(queue: DispatchQueue(label: "com.cc-controller.connection-path"))
        pathMonitor = monitor
    }
}

public func relayEndpointLabel(for endpoint: URL) -> String {
    guard let host = endpoint.host else { return endpoint.absoluteString }
    let octets = host.split(separator: ".").compactMap { Int($0) }
    if octets.count == 4 {
        if octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168) {
            return "Home network"
        }
        if octets[0] == 100 && (64...127).contains(octets[1]) {
            return "Tailscale"
        }
    }
    return host
}

public func isNetworkRelayError(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed, .cannotFindHost:
        true
    default:
        false
    }
}
