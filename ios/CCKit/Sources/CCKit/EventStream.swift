import Foundation

public actor EventStream {
    public nonisolated let events: AsyncStream<LiveEvent>
    public nonisolated let statuses: AsyncStream<ConnectionStatus>

    private let client: APIClient
    private let session: URLSession
    private let eventContinuation: AsyncStream<LiveEvent>.Continuation
    private let statusContinuation: AsyncStream<ConnectionStatus>.Continuation
    private var task: Task<Void, Never>?

    public init(client: APIClient, session: URLSession = .shared) {
        self.client = client
        self.session = session
        var eventContinuation: AsyncStream<LiveEvent>.Continuation!
        var statusContinuation: AsyncStream<ConnectionStatus>.Continuation!
        self.events = AsyncStream { eventContinuation = $0 }
        self.statuses = AsyncStream { statusContinuation = $0 }
        self.eventContinuation = eventContinuation
        self.statusContinuation = statusContinuation
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
        while !Task.isCancelled {
            if attempt == 0 { statusContinuation.yield(.connecting) }
            else { statusContinuation.yield(.reconnecting(attempt: attempt)) }
            do {
                var request = await client.eventRequest()
                request.timeoutInterval = 45
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw APIError.decoding("Event response was not HTTP") }
                guard (200..<300).contains(response.statusCode) else {
                    if response.statusCode == 401 { await client.reportAuthenticationFailure() }
                    throw APIError.http(status: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
                }
                attempt = 0
                statusContinuation.yield(.live)
                eventContinuation.yield(.connected)
                try await consume(bytes)
                if Task.isCancelled { break }
                throw APIError.http(status: 599, message: "Event stream ended")
            } catch is CancellationError {
                break
            } catch {
                statusContinuation.yield(.offline)
                if Task.isCancelled { break }
                attempt += 1
                let delay = backoff(attempt: attempt)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { break }
            }
        }
    }

    private func consume(_ bytes: URLSession.AsyncBytes) async throws {
        var parser = SSEParser()
        for try await line in bytes.lines {
            if let event = parser.consume(line), let decoded = LiveEvent.decode(name: event.name, data: event.data) {
                eventContinuation.yield(decoded)
            }
        }
        if let event = parser.finish(), let decoded = LiveEvent.decode(name: event.name, data: event.data) {
            eventContinuation.yield(decoded)
        }
    }

    private func backoff(attempt: Int) -> Double {
        let base = min(15.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        let jitter = Double.random(in: -0.2...0.2)
        return max(0.05, base * (1 + jitter))
    }
}
