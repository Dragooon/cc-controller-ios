import Foundation

public struct TranscriptLifecycleEvent: Codable, Equatable, Sendable {
    public let at: String
    public let name: String
    public let session: String?
    public let detail: String?

    public init(at: String, name: String, session: String? = nil, detail: String? = nil) {
        self.at = at
        self.name = name
        self.session = session
        self.detail = detail
    }
}

public struct TranscriptGapDiagnosticRecord: Codable, Equatable, Sendable {
    public let timestamp: String
    public let name: String
    public let sessionID: String?
    public let serverTotal: Int
    public let confirmedTotal: Int
    public let attempt: Int
    public let errorType: String?

    public init(
        timestamp: String,
        name: String,
        sessionID: String?,
        serverTotal: Int,
        confirmedTotal: Int,
        attempt: Int,
        errorType: String? = nil
    ) {
        self.timestamp = timestamp
        self.name = name
        self.sessionID = sessionID
        self.serverTotal = serverTotal
        self.confirmedTotal = confirmedTotal
        self.attempt = attempt
        self.errorType = errorType
    }
}

public actor TranscriptGapDiagnosticsFileStore {
    public static let maximumLineCount = 500
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    @discardableResult
    public func append(_ record: TranscriptGapDiagnosticRecord) -> Bool {
        do {
            let encoder = JSONEncoder()
            let line = try encoder.encode(record)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existing = (try? String(contentsOf: url, encoding: .utf8))?
                .split(separator: "\\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []
            let lines = Array((existing + [String(decoding: line, as: UTF8.self)]).suffix(Self.maximumLineCount))
            try lines.joined(separator: "\\n").appending("\\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    public func readLines() -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\\n", omittingEmptySubsequences: true).map(String.init)
    }
}

@MainActor
public final class TranscriptLifecycleLog {
    public static let shared = TranscriptLifecycleLog()
    #if DEBUG
    public static let eventNotification = Notification.Name("CCControllerTranscriptLifecycleEvent")
    #endif
    public static let capacity = 64
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let clock: () -> Date
    private let gapFileStore: TranscriptGapDiagnosticsFileStore
    private var storage: [TranscriptLifecycleEvent] = []

    public init(
        clock: @escaping () -> Date = Date.init,
        gapFileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transcript-gap-diagnostics.jsonl")
    ) {
        self.clock = clock
        self.gapFileStore = TranscriptGapDiagnosticsFileStore(url: gapFileURL)
    }

    public var events: [TranscriptLifecycleEvent] { storage }

    public func record(
        name: String,
        sessionID: String? = nil,
        detail: String? = nil
    ) {
        let timestamp = Self.timestampFormatter.string(from: clock())
        let sessionPrefix = Self.sessionPrefix(sessionID)
        let event = TranscriptLifecycleEvent(
            at: timestamp,
            name: name,
            session: sessionPrefix,
            detail: detail.map { String($0.prefix(39)) }
        )
        storage.append(event)
        #if DEBUG
        NotificationCenter.default.post(
            name: Self.eventNotification,
            object: nil,
            userInfo: [
                "at": timestamp,
                "name": name,
                "session": sessionPrefix as Any,
                "detail": detail as Any
            ]
        )
        #endif
        if storage.count > Self.capacity {
            storage.removeFirst(storage.count - Self.capacity)
        }
    }

    public func recordGap(
        name: String,
        sessionID: String?,
        serverTotal: Int,
        confirmedTotal: Int,
        attempt: Int = 0,
        errorType: String? = nil
    ) {
        let now = clock()
        record(
            name: name,
            sessionID: sessionID,
            detail: "server=\(serverTotal),confirmed=\(confirmedTotal),attempt=\(attempt)"
        )
        let timestamp = Self.timestampFormatter.string(from: now)
        let record = TranscriptGapDiagnosticRecord(
            timestamp: timestamp,
            name: name,
            sessionID: sessionID,
            serverTotal: serverTotal,
            confirmedTotal: confirmedTotal,
            attempt: attempt,
            errorType: errorType
        )
        let fileStore = gapFileStore
        Task { await fileStore.append(record) }
    }

    public func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }

    public static func sessionPrefix(_ sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return String(sessionID.prefix(8))
    }
}

public enum TranscriptScreenBranch: String, Sendable {
    case transcript
    case loadingNoStore = "loading-nostore"
    case loadingUnloaded = "loading-unloaded"
}

public enum TranscriptLifecycleTrigger: Equatable, Sendable {
    case reload(sessionID: String)

    public var kind: ScrollBlankKind {
        switch self {
        case .reload: .reload
        }
    }

    public var sessionID: String {
        switch self {
        case .reload(let sessionID): sessionID
        }
    }
}

public enum TranscriptLifecycleTriggerInput: Sendable {
    case screenBranch(screenID: String, sessionID: String, branch: TranscriptScreenBranch)
}

/// Pure trigger state machine. The caller supplies time so lifecycle behavior is deterministic in tests.
public struct TranscriptLifecycleTriggerEngine {
    public typealias Clock = @Sendable () -> Date

    private let clock: Clock
    private var screenBranches: [String: TranscriptScreenBranch] = [:]
    private var lastTriggerAt: [ScrollBlankKind: Date] = [:]

    public init(clock: @escaping Clock = { Date() }) {
        self.clock = clock
    }

    public mutating func ingest(_ input: TranscriptLifecycleTriggerInput) -> [TranscriptLifecycleTrigger] {
        let now = clock()
        switch input {
        case .screenBranch(let screenID, let sessionID, let branch):
            let previous = screenBranches.updateValue(branch, forKey: screenID)
            guard previous == .transcript, branch != .transcript else { return [] }
            return emit(.reload(sessionID: sessionID), at: now)
        }
    }

    private mutating func emit(_ trigger: TranscriptLifecycleTrigger, at now: Date) -> [TranscriptLifecycleTrigger] {
        let kind = trigger.kind
        if let previous = lastTriggerAt[kind], now.timeIntervalSince(previous) < 10 {
            return []
        }
        lastTriggerAt[kind] = now
        return [trigger]
    }
}

@MainActor
public final class TranscriptLifecycleDiagnostics {
    public static let shared = TranscriptLifecycleDiagnostics()

    private var engine = TranscriptLifecycleTriggerEngine()

    public init() {}

    public func ingest(_ input: TranscriptLifecycleTriggerInput) -> [TranscriptLifecycleTrigger] {
        engine.ingest(input)
    }

    public func reset() {
        engine = TranscriptLifecycleTriggerEngine()
    }
}
