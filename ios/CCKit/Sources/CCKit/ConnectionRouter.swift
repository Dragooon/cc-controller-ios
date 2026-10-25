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
    case pinRequired

    public var errorDescription: String? {
        switch self {
        case .noReachableEndpoint: "No relay endpoint is reachable."
        case .pinRequired: "A relay pin is required before authenticated traffic."
        }
    }
}

/// Owns the transport selected for the daemon API and event stream.
public final class ConnectionRouter: @unchecked Sendable {
    public let mode: Mode
    public let relayHostID: ControllerID?

    public enum Mode: Sendable, Equatable {
        case direct
        case relay
    }

    private let directURL: URL?
    private let directSession: URLSession?
    private let pinLoader: (@Sendable () async -> RelayPin?)?
    private let lock = NSLock()
    private var endpoints: [URL]
    private var relaySession: RelaySession?
    private var selector: RelayEndpointSelector?
    private var selected: ConnectionTarget?
    private var pathMonitor: NWPathMonitor?
    private var resolvedPin: RelayPin?
    private var pinResolved: Bool
    private var pinResolutionTask: Task<RelayPin?, Never>?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public init(baseURL: URL, session: URLSession = .shared, relayHostID: ControllerID? = nil) {
        mode = .direct
        self.relayHostID = relayHostID
        endpoints = [baseURL]
        directURL = baseURL
        directSession = session
        pinLoader = nil
        pinResolved = true
    }

    public init(
        endpoints: [URL],
        pin: RelayPin? = nil,
        pinLoader: (@Sendable () async -> RelayPin?)? = nil,
        relayHostID: ControllerID? = nil
    ) {
        mode = .relay
        self.relayHostID = relayHostID
        self.endpoints = endpoints
        directURL = nil
        directSession = nil
        self.pinLoader = pinLoader
        resolvedPin = pin
        pinResolved = pin != nil || pinLoader == nil
        let relay = RelaySessionFactory.make(
            endpoints: endpoints,
            mode: pin.map(PinnedTrustDelegate.Mode.pinned) ?? .trustOnFirstUse,
            hostID: relayHostID
        )
        relaySession = relay
        selector = RelayEndpointSelector(endpoints: endpoints, session: relay.session, trustDelegate: relay.trustDelegate)
        startPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    public var configuredEndpoints: [URL] {
        withLock { endpoints }
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

    public var usesPinnedTrust: Bool {
        withLock { relaySession?.trustDelegate.isPinned == true }
    }

    public func target(allowTOFU: Bool = false) async throws -> ConnectionTarget {
        if mode == .direct {
            return ConnectionTarget(baseURL: directURL!, session: directSession!)
        }
        let pin = await resolvePin()
        guard allowTOFU || pin != nil else { throw ConnectionRouterError.pinRequired }
        if pin != nil && !usesPinnedTrust {
            replaceRelaySession(endpoints: configuredEndpoints, pin: pin)
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
        let selector = withLock { self.selector }
        guard let selector else { return [:] }
        return await selector.outcomes()
    }

    public func trustFailure(for endpoint: URL) -> PinnedTrustDelegate.Failure? {
        withLock { relaySession?.trustDelegate.failure(for: endpoint) }
    }

    public func reconfigure(pin: RelayPin?) async {
        guard mode == .relay else { return }
        withLock {
            resolvedPin = pin
            pinResolved = true
            pinResolutionTask = nil
        }
        replaceRelaySession(endpoints: configuredEndpoints, pin: pin)
    }

    public func updateEndpoints(_ endpoints: [URL], pin: RelayPin?) async {
        guard mode == .relay else { return }
        withLock {
            self.endpoints = endpoints
            resolvedPin = pin
            pinResolved = true
            pinResolutionTask = nil
        }
        replaceRelaySession(endpoints: endpoints, pin: pin)
    }

    private func resolvePin() async -> RelayPin? {
        guard mode == .relay else { return nil }
        let task = withLock { () -> Task<RelayPin?, Never>? in
            if pinResolved { return nil }
            if let pinResolutionTask { return pinResolutionTask }
            let task = Task { [pinLoader] in await pinLoader?() }
            pinResolutionTask = task
            return task
        }
        guard let task else { return withLock { resolvedPin } }
        let pin = await task.value
        let shouldReplace = withLock { () -> Bool in
            resolvedPin = pin
            pinResolved = true
            pinResolutionTask = nil
            return pin != nil && relaySession?.trustDelegate.isPinned != true
        }
        if shouldReplace { replaceRelaySession(endpoints: configuredEndpoints, pin: pin) }
        return pin
    }

    private func replaceRelaySession(endpoints: [URL], pin: RelayPin?) {
        let relay = RelaySessionFactory.make(
            endpoints: endpoints,
            mode: pin.map(PinnedTrustDelegate.Mode.pinned) ?? .trustOnFirstUse,
            hostID: relayHostID
        )
        let nextSelector = RelayEndpointSelector(
            endpoints: endpoints,
            session: relay.session,
            trustDelegate: relay.trustDelegate
        )
        let oldSession = withLock { () -> URLSession? in
            let old = relaySession?.session
            self.endpoints = endpoints
            relaySession = relay
            selector = nextSelector
            selected = nil
            return old
        }
        oldSession?.finishTasksAndInvalidate()
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
