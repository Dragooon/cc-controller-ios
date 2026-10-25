import Foundation

public enum RelayEndpointOutcome: Sendable, Equatable {
    case reachable
    case pinMismatch
    case timedOut
    case failed(code: Int)
}

public struct RelayEndpointSelection: Sendable, Equatable {
    public let endpoint: URL
    public let outcomes: [URL: RelayEndpointOutcome]

    public init(endpoint: URL, outcomes: [URL: RelayEndpointOutcome]) {
        self.endpoint = endpoint
        self.outcomes = outcomes
    }
}

public typealias RelayEndpointProber = @Sendable (URL, TimeInterval) async -> RelayEndpointOutcome

public actor RelayEndpointSelector {
    public static let endpointTimeout: TimeInterval = 2.5
    public static let preferenceWindow: Duration = .milliseconds(300)

    private struct Completion: Sendable {
        let index: Int
        let outcome: RelayEndpointOutcome
    }

    private actor CompletionState {
        var outcomes: [Int: RelayEndpointOutcome] = [:]
        var successes: Set<Int> = []

        func record(_ completion: Completion) {
            outcomes[completion.index] = completion.outcome
            if case .reachable = completion.outcome { successes.insert(completion.index) }
        }

        func snapshot() -> (outcomes: [Int: RelayEndpointOutcome], successes: Set<Int>) {
            (outcomes, successes)
        }
    }

    private let endpoints: [URL]
    private let prober: RelayEndpointProber
    private let clock: any CCKitClock
    private var cachedSelection: RelayEndpointSelection?
    private var latestOutcomes: [URL: RelayEndpointOutcome] = [:]

    public init(
        endpoints: [URL],
        prober: @escaping RelayEndpointProber,
        clock: any CCKitClock = SystemCCKitClock()
    ) {
        self.endpoints = endpoints
        self.prober = prober
        self.clock = clock
    }

    public init(
        endpoints: [URL],
        session: URLSession,
        trustDelegate: PinnedTrustDelegate? = nil,
        clock: any CCKitClock = SystemCCKitClock()
    ) {
        self.init(
            endpoints: endpoints,
            prober: Self.makeProber(session: session, trustDelegate: trustDelegate),
            clock: clock
        )
    }

    public func select() async -> RelayEndpointSelection? {
        if let cachedSelection { return cachedSelection }
        guard !endpoints.isEmpty else { return nil }
        latestOutcomes = [:]

        let state = CompletionState()
        let (stream, continuation) = AsyncStream<Completion>.makeStream()
        let tasks = endpoints.enumerated().map { index, endpoint in
            Task {
                let completion = Completion(index: index, outcome: await prober(endpoint, Self.endpointTimeout))
                await state.record(completion)
                continuation.yield(completion)
            }
        }
        defer {
            tasks.forEach { $0.cancel() }
            continuation.finish()
        }

        var iterator = stream.makeAsyncIterator()
        var outcomes: [URL: RelayEndpointOutcome] = [:]
        var successes: Set<Int> = []
        var completed = 0

        while completed < endpoints.count {
            guard let completion = await iterator.next() else { break }
            completed += 1
            outcomes[endpoints[completion.index]] = completion.outcome
            latestOutcomes = outcomes
            if case .reachable = completion.outcome {
                successes.insert(completion.index)
                if completion.index == 0 || allEarlierEndpointsHaveFinished(before: completion.index, outcomes: outcomes) {
                    return cache(index: successes.min() ?? completion.index, outcomes: outcomes)
                }

                try? await clock.sleep(for: Self.preferenceWindow)
                let snapshot = await state.snapshot()
                for (index, outcome) in snapshot.outcomes {
                    outcomes[endpoints[index]] = outcome
                }
                successes.formUnion(snapshot.successes)
                if let index = successes.min() {
                    return cache(index: index, outcomes: outcomes)
                }
            }
        }

        guard let index = successes.min() else { return nil }
        return cache(index: index, outcomes: outcomes)
    }

    public func invalidate() {
        cachedSelection = nil
    }

    public func outcomes() -> [URL: RelayEndpointOutcome] {
        latestOutcomes
    }

    private func allEarlierEndpointsHaveFinished(before index: Int, outcomes: [URL: RelayEndpointOutcome]) -> Bool {
        endpoints[..<index].allSatisfy { outcomes[$0] != nil }
    }

    private func cache(index: Int, outcomes: [URL: RelayEndpointOutcome]) -> RelayEndpointSelection {
        let selection = RelayEndpointSelection(endpoint: endpoints[index], outcomes: outcomes)
        cachedSelection = selection
        return selection
    }

    static func makeProber(session: URLSession, trustDelegate: PinnedTrustDelegate?) -> RelayEndpointProber {
        { endpoint, timeout in
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + [basePath, "api/auth/whoami"].filter { !$0.isEmpty }.joined(separator: "/")
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            do {
                let (_, response) = try await session.data(for: request)
                guard response is HTTPURLResponse else { return .failed(code: -1) }
                return .reachable
            } catch let error as URLError {
                if trustDelegate?.failure(for: endpoint) != nil { return .pinMismatch }
                if error.code == .timedOut { return .timedOut }
                return .failed(code: error.errorCode)
            } catch {
                if trustDelegate?.failure(for: endpoint) != nil { return .pinMismatch }
                return .failed(code: -1)
            }
        }
    }
}
