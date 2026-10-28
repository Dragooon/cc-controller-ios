import Foundation

public actor EventStream {
    public nonisolated let events: AsyncStream<LiveEvent>
    public nonisolated let statuses: AsyncStream<ConnectionStatus>
    public nonisolated let unknownEvents: AsyncStream<String>

    private let client: APIClient
    private let clock: any CCKitClock
    private let beforeReconnect: (@Sendable (Int) async -> Bool)?
    private let eventContinuation: AsyncStream<LiveEvent>.Continuation
    private let statusContinuation: AsyncStream<ConnectionStatus>.Continuation
    private let unknownContinuation: AsyncStream<String>.Continuation
    private var task: Task<Void, Never>?

    public init(
        client: APIClient,
        session: URLSession = .shared,
        clock: any CCKitClock = SystemCCKitClock(),
        beforeReconnect: (@Sendable (Int) async -> Bool)? = nil
    ) {
        self.client = client
        self.clock = clock
        self.beforeReconnect = beforeReconnect
        var eventContinuation: AsyncStream<LiveEvent>.Continuation!
        var statusContinuation: AsyncStream<ConnectionStatus>.Continuation!
        var unknownContinuation: AsyncStream<String>.Continuation!
        self.events = AsyncStream { eventContinuation = $0 }
        self.statuses = AsyncStream { statusContinuation = $0 }
        self.unknownEvents = AsyncStream { unknownContinuation = $0 }
        self.eventContinuation = eventContinuation
        self.statusContinuation = statusContinuation
        self.unknownContinuation = unknownContinuation
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        statusContinuation.yield(.offline)
    }

    private func run() async {
        var attempt = 0
        var isFirstAttempt = true
        let startedAt = clock.now
        while !Task.isCancelled {
            if attempt == 0 {
                statusContinuation.yield(.connecting)
            } else {
                let delay = backoff(attempt: attempt)
                do { try await clock.sleep(for: .nanoseconds(Int64(delay * 1_000_000_000))) } catch { break }
                guard !Task.isCancelled else { break }
                if let beforeReconnect, await !beforeReconnect(attempt) { break }
                statusContinuation.yield(.reconnecting(attempt: attempt))
            }
            do {
                var request = await client.eventRequest()
                request.timeoutInterval = 45
                let target = try await client.connection.target()
                let (bytes, response) = try await target.session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw APIError.decoding("Event response was not HTTP")
                }
                guard (200..<300).contains(response.statusCode) else {
                    if response.statusCode == 401 { await client.reportAuthenticationFailure() }
                    throw APIError.http(status: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode), code: nil)
                }
                attempt = 0
                statusContinuation.yield(.live)
                eventContinuation.yield(.connected)
                try await consume(bytes)
                if Task.isCancelled { break }
                throw APIError.http(status: 599, message: "Event stream ended", code: nil)
            } catch is CancellationError {
                break
            } catch let error as URLError {
                if isNetworkRelayError(error) { client.connection.invalidate() }
                if isFirstAttempt {
                    isFirstAttempt = false
                    if shouldRetryImmediately(error, startedAt: startedAt) { continue }
                }
                statusContinuation.yield(.offline)
                if Task.isCancelled { break }
                attempt += 1
            } catch {
                statusContinuation.yield(.offline)
                if Task.isCancelled { break }
                attempt += 1
            }
        }
    }

    private func consume(_ bytes: URLSession.AsyncBytes) async throws {
        var parser = SSEParser()
        var line = Data()
        for try await byte in bytes {
            if byte == 10 {
                if let event = parser.consume(String(decoding: line, as: UTF8.self)) { emit(event) }
                line.removeAll(keepingCapacity: true)
                continue
            }
            line.append(byte)
        }
        if !line.isEmpty, let event = parser.consume(String(decoding: line, as: UTF8.self)) { emit(event) }
        if let event = parser.finish() { emit(event) }
    }

    private func emit(_ event: SSEEvent) {
        if let decoded = LiveEvent.decode(name: event.name, data: event.data) {
            eventContinuation.yield(decoded)
            return
        }
        if event.name != "hook" { unknownContinuation.yield(event.name) }
    }

    private func shouldRetryImmediately(_ error: URLError, startedAt: Date) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost:
            return true
        case .networkConnectionLost, .notConnectedToInternet:
            return clock.now.timeIntervalSince(startedAt) <= 2
        default:
            return false
        }
    }

    private func backoff(attempt: Int) -> Double {
        ConnectionBackoff.seconds(attempt: attempt)
    }
}
