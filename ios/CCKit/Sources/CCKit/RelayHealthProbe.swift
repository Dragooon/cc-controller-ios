import Foundation
import Network

public struct RelayHealth: Sendable, Equatable {
    public let macConnected: Bool
    public let pending: Int
    public let streams: Int

    public init(macConnected: Bool, pending: Int, streams: Int) {
        self.macConnected = macConnected
        self.pending = pending
        self.streams = streams
    }
}

public enum RelayHealthProbeError: Error, Sendable, Equatable, LocalizedError {
    case invalidEndpoint
    case timedOut
    case malformedReply(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Relay health probe requires an IP endpoint with a port."
        case .timedOut: "Relay health probe timed out."
        case .malformedReply(let reply): "Relay returned a malformed health reply: \(reply)"
        case .network(let message): "Relay health probe failed: \(message)"
        }
    }
}

public func parseRelayHealthLine(_ line: String) throws -> RelayHealth {
    let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count == 4, fields[0] == "OK" else {
        throw RelayHealthProbeError.malformedReply(line)
    }

    var host: Bool?
    var pending: Int?
    var streams: Int?
    for field in fields.dropFirst() {
        let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw RelayHealthProbeError.malformedReply(line) }
        switch parts[0] {
        case "host":
            guard parts[1] == "0" || parts[1] == "1" else { throw RelayHealthProbeError.malformedReply(line) }
            host = parts[1] == "1"
        case "pending":
            guard let value = Int(parts[1]), value >= 0 else { throw RelayHealthProbeError.malformedReply(line) }
            pending = value
        case "streams":
            guard let value = Int(parts[1]), value >= 0 else { throw RelayHealthProbeError.malformedReply(line) }
            streams = value
        default:
            throw RelayHealthProbeError.malformedReply(line)
        }
    }
    guard let host, let pending, let streams else {
        throw RelayHealthProbeError.malformedReply(line)
    }
    return RelayHealth(macConnected: host, pending: pending, streams: streams)
}

public final class RelayHealthProbe: @unchecked Sendable {
    public let endpoint: URL
    public let timeout: TimeInterval

    public init(endpoint: URL, timeout: TimeInterval = 2) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func probe() async throws -> RelayHealth {
        guard let host = endpoint.host,
              let port = endpoint.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw RelayHealthProbeError.invalidEndpoint
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let operation = HealthOperation(connection: connection)
        return try await operation.run(timeout: timeout)
    }
}

private final class HealthOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RelayHealth, Error>?
    private var buffer = Data()
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func run(timeout: TimeInterval) async throws -> RelayHealth {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RelayHealth, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.sendHealthRequest()
                    case .failed(let error):
                        self.finish(.failure(.network(error.localizedDescription)))
                    case .cancelled:
                        self.finish(.failure(.network("Connection cancelled.")))
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "com.cc-controller.relay-health"))
                Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(Int64(timeout * 1_000)))
                        self?.finish(.failure(.timedOut))
                    } catch { }
                }
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(.network("Probe cancelled.")))
        }
    }

    private func sendHealthRequest() {
        connection.send(content: Data("CCR1 HEALTH\n".utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failure(.network(error.localizedDescription))); return }
            self?.receive()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.finish(.failure(.network(error.localizedDescription))); return }
            if let data { self.append(data) }
            if self.hasLine {
                self.finishWithLine()
            } else if isComplete {
                self.finish(.failure(.malformedReply(String(decoding: self.buffer, as: UTF8.self))))
            } else {
                self.receive()
            }
        }
    }

    private var hasLine: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.contains(10)
    }

    private func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    private func finishWithLine() {
        lock.lock()
        let line = buffer.prefix { $0 != 10 }
        lock.unlock()
        do { finish(.success(try parseRelayHealthLine(String(decoding: line, as: UTF8.self)))) }
        catch let error as RelayHealthProbeError { finish(.failure(error)) }
        catch { finish(.failure(.malformedReply(String(decoding: line, as: UTF8.self)))) }
    }

    private func finish(_ result: Result<RelayHealth, RelayHealthProbeError>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(with: result)
    }
}
