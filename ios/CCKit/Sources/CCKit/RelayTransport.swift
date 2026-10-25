import Foundation
import Network
import Security

public final class PinnedTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        case pinned(RelayPin)
        case trustOnFirstUse
    }

    public enum Failure: Sendable, Equatable {
        case pinMismatch(observed: String)
    }

    private let hosts: Set<String>
    private let mode: Mode
    private let lock = NSLock()
    private var failure: Failure?
    private var failures: [String: Failure] = [:]
    private var pin: String?

    public init(endpoints: [URL], mode: Mode) {
        hosts = Set(endpoints.compactMap { $0.host?.lowercased() })
        self.mode = mode
    }

    public var isPinned: Bool {
        if case .pinned = mode { return true }
        return false
    }

    public var lastFailure: Failure? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    public var observedPin: String? {
        lock.lock()
        defer { lock.unlock() }
        return pin
    }

    public func failure(for endpoint: URL) -> Failure? {
        guard let host = endpoint.host?.lowercased() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return failures[host]
    }

    /// Failures remain sticky until this host presents a matching key again.
    public func clearFailure(for endpoint: URL) {
        // Kept for source compatibility; callers must not clear trust failures speculatively.
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              hosts.contains(challenge.protectionSpace.host.lowercased()),
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        do {
            guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                throw RelayPinError.invalidCertificateChain
            }
            let observed = try RelayPin.spkiSHA256(of: leaf)
            switch mode {
            case .pinned(let expected):
                guard observed == expected.value else {
                    lock.lock()
                    let mismatch = Failure.pinMismatch(observed: observed)
                    failure = mismatch
                    failures[challenge.protectionSpace.host.lowercased()] = mismatch
                    lock.unlock()
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
            case .trustOnFirstUse:
                lock.lock()
                if let pin, pin != observed {
                    let mismatch = Failure.pinMismatch(observed: observed)
                    failure = mismatch
                    failures[challenge.protectionSpace.host.lowercased()] = mismatch
                    lock.unlock()
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                pin = observed
                lock.unlock()
            }
            let host = challenge.protectionSpace.host.lowercased()
            lock.lock()
            failures.removeValue(forKey: host)
            failure = failures.values.first
            lock.unlock()
            completionHandler(.useCredential, URLCredential(trust: trust))
        } catch {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public struct RelaySession: @unchecked Sendable {
    public let session: URLSession
    public let trustDelegate: PinnedTrustDelegate
    public let openPreamble: Data

    public init(session: URLSession, trustDelegate: PinnedTrustDelegate, openPreamble: Data = Data()) {
        self.session = session
        self.trustDelegate = trustDelegate
        self.openPreamble = openPreamble
    }
}

public enum RelayTransportError: Error, Sendable, Equatable, LocalizedError {
    case relayRejected(hostID: ControllerID, line: String)

    public var errorDescription: String? {
        switch self {
        case .relayRejected(let hostID, let line):
            "Relay host \(hostID.rawValue) rejected the connection: \(line)"
        }
    }
}

public enum RelayTransport {
    public static func openPreamble(for hostID: ControllerID?) -> Data {
        guard let hostID, hostID != .mac else { return Data() }
        return Data("CCR1 OPEN \(hostID.rawValue)\n".utf8)
    }

    public static func writeOpen(
        to connection: NWConnection,
        hostID: ControllerID?,
        completion: @escaping @Sendable (NWError?) -> Void
    ) {
        let preamble = openPreamble(for: hostID)
        guard !preamble.isEmpty else {
            completion(nil)
            return
        }
        connection.send(content: preamble, completion: .contentProcessed(completion))
    }

    public static func rejection(in data: Data, hostID: ControllerID) -> RelayTransportError? {
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first,
              line.hasPrefix("ERR ") else { return nil }
        return .relayRejected(hostID: hostID, line: String(line))
    }
}

public enum RelaySessionFactory {
    public static func make(endpoints: [URL], mode: PinnedTrustDelegate.Mode, hostID: ControllerID? = nil) -> RelaySession {
        let delegate = PinnedTrustDelegate(endpoints: endpoints, mode: mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return RelaySession(
            session: URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil),
            trustDelegate: delegate,
            openPreamble: RelayTransport.openPreamble(for: hostID)
        )
    }

    public static func makeSession(endpoints: [URL], mode: PinnedTrustDelegate.Mode, hostID: ControllerID? = nil) -> URLSession {
        make(endpoints: endpoints, mode: mode, hostID: hostID).session
    }
}
