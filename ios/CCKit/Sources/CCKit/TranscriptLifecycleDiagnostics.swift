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
    private var storage: [TranscriptLifecycleEvent] = []

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
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
    case remount(sessionID: String)
    case reload(sessionID: String)
    case sentinelUnbuilt(sessionID: String)

    public var kind: ScrollBlankKind {
        switch self {
        case .remount: .remount
        case .reload: .reload
        case .sentinelUnbuilt: .sentinelUnbuilt
        }
    }

    public var sessionID: String {
        switch self {
        case .remount(let sessionID), .reload(let sessionID), .sentinelUnbuilt(let sessionID): sessionID
        }
    }
}

public enum TranscriptLifecycleTriggerInput: Sendable {
    case transcriptAppear(sessionID: String)
    case transcriptDisappear(sessionID: String)
    case screenBranch(screenID: String, sessionID: String, branch: TranscriptScreenBranch)
    case rowsMounted(sessionID: String, mounted: Bool)
    case pinned(sessionID: String, pinned: Bool)
    case scrollIdle(sessionID: String, idle: Bool)
    case sentinelBuilt(sessionID: String, built: Bool)
    case sentinelCheck(sessionID: String)
}

public struct TranscriptLifecycleIngestResult: Equatable, Sendable {
    public let triggers: [TranscriptLifecycleTrigger]
    public let corrections: [TranscriptLifecycleTrigger]

    public init(
        triggers: [TranscriptLifecycleTrigger],
        corrections: [TranscriptLifecycleTrigger]
    ) {
        self.triggers = triggers
        self.corrections = corrections
    }
}

/// Pure trigger state machine. The caller supplies time so lifecycle behavior is deterministic in tests.
public struct TranscriptLifecycleTriggerEngine {
    public typealias Clock = @Sendable () -> Date

    private struct SentinelState {
        var built = true
        var rowsMounted = false
        var pinned = true
        var idle = true
        var unbuiltSince: Date?
        var emitted = false
    }

    private let clock: Clock
    private var transcriptDisappearedAt: [String: Date] = [:]
    private var screenBranches: [String: TranscriptScreenBranch] = [:]
    private var sentinels: [String: SentinelState] = [:]
    private var lastTriggerAt: [ScrollBlankKind: Date] = [:]
    private var pendingCorrections: [TranscriptLifecycleTrigger] = []

    public init(clock: @escaping Clock = { Date() }) {
        self.clock = clock
    }

    public mutating func ingestWithCorrections(_ input: TranscriptLifecycleTriggerInput) -> TranscriptLifecycleIngestResult {
        let triggers = ingest(input)
        return TranscriptLifecycleIngestResult(triggers: triggers, corrections: pendingCorrections)
    }

    public mutating func ingest(_ input: TranscriptLifecycleTriggerInput) -> [TranscriptLifecycleTrigger] {
        pendingCorrections = []
        let now = clock()
        switch input {
        case .transcriptDisappear(let sessionID):
            transcriptDisappearedAt[sessionID] = now
            return []
        case .transcriptAppear(let sessionID):
            guard let disappearedAt = transcriptDisappearedAt.removeValue(forKey: sessionID),
                  now.timeIntervalSince(disappearedAt) >= 0,
                  now.timeIntervalSince(disappearedAt) <= 5 else { return [] }
            return emit(.remount(sessionID: sessionID), at: now)
        case .screenBranch(let screenID, let sessionID, let branch):
            let previous = screenBranches.updateValue(branch, forKey: screenID)
            guard previous == .transcript, branch != .transcript else { return [] }
            return emit(.reload(sessionID: sessionID), at: now)
        case .rowsMounted(let sessionID, let mounted):
            var state = sentinels[sessionID, default: SentinelState()]
            state.rowsMounted = mounted
            updateSentinelEligibility(&state, at: now)
            sentinels[sessionID] = state
            return []
        case .pinned(let sessionID, let pinned):
            var state = sentinels[sessionID, default: SentinelState()]
            state.pinned = pinned
            updateSentinelEligibility(&state, at: now)
            sentinels[sessionID] = state
            return []
        case .scrollIdle(let sessionID, let idle):
            var state = sentinels[sessionID, default: SentinelState()]
            state.idle = idle
            updateSentinelEligibility(&state, at: now)
            sentinels[sessionID] = state
            return []
        case .sentinelBuilt(let sessionID, let built):
            var state = sentinels[sessionID, default: SentinelState()]
            state.built = built
            if built {
                state.unbuiltSince = nil
                state.emitted = false
            } else {
                state.emitted = false
                updateSentinelEligibility(&state, at: now)
            }
            sentinels[sessionID] = state
            return []
        case .sentinelCheck(let sessionID):
            var state = sentinels[sessionID, default: SentinelState()]
            updateSentinelEligibility(&state, at: now)
            guard !state.built,
                  state.rowsMounted,
                  state.pinned,
                  state.idle,
                  !state.emitted,
                  let unbuiltSince = state.unbuiltSince,
                  now.timeIntervalSince(unbuiltSince) >= 0.3 - 0.000_001 else {
                sentinels[sessionID] = state
                return []
            }
            state.emitted = true
            sentinels[sessionID] = state
            let trigger = TranscriptLifecycleTrigger.sentinelUnbuilt(sessionID: sessionID)
            pendingCorrections = [trigger]
            return emit(trigger, at: now)
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

    private func updateSentinelEligibility(_ state: inout SentinelState, at now: Date) {
        guard !state.built, state.rowsMounted, state.pinned, state.idle else {
            state.unbuiltSince = nil
            state.emitted = false
            return
        }
        state.unbuiltSince = state.unbuiltSince ?? now
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

    public func ingestWithCorrections(_ input: TranscriptLifecycleTriggerInput) -> TranscriptLifecycleIngestResult {
        engine.ingestWithCorrections(input)
    }

    public func reset() {
        engine = TranscriptLifecycleTriggerEngine()
    }
}
