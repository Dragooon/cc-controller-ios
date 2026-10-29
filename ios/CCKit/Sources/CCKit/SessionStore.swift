import Foundation
import Observation

#if DEBUG
func postCCMotionTraceEvent(_ name: String, data: [String: Any] = [:]) {
    NotificationCenter.default.post(
        name: Notification.Name("CCMotionTraceEvent"),
        object: nil,
        userInfo: ["name": name, "data": data]
    )
}
#endif

private struct SessionStoreClock: CCKitClock, @unchecked Sendable {
    let nowProvider: () -> Date

    var now: Date { nowProvider() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public enum TranscriptReadiness: Sendable, Equatable {
    case ready
    case syncing
}

@MainActor @Observable
public final class SessionStore {
    public let sessionID: String
    public let agentID: String?
    public private(set) var session: Session
    public private(set) var transcriptStore: TranscriptStore
    public private(set) var turns: [Turn] = []
    public private(set) var rows: [TranscriptRow] = []
    public private(set) var hasMoreEarlier = false
    /// The latest transcript count reported by the daemon or a transcript page.
    public private(set) var serverTotal = 0
    /// The count through which the local transcript is known to be complete.
    public private(set) var confirmedTotal = 0
    public private(set) var syncedRev: Int?
    public private(set) var syncedEpoch: String?
    public private(set) var readiness: TranscriptReadiness = .syncing
    public var totalEntries: Int { serverTotal }
    public var hasTranscriptGap: Bool { transcriptGap }
    public var entries: [TranscriptEntry] { transcriptStore.entries }

    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let onTranscriptChange: (([TranscriptEntry]) -> Void)?
    @ObservationIgnored private let clock: any CCKitClock
    @ObservationIgnored private let initialTranscriptTail: Int
    @ObservationIgnored private var transcriptOnly: Bool
    @ObservationIgnored private var loadingEarlier = false
    @ObservationIgnored private var inFlightTranscriptFetch: TranscriptFetch?
    @ObservationIgnored private var pendingRefetch: PendingRefetch?
    @ObservationIgnored private var gapResyncTask: Task<Void, Never>?
    @ObservationIgnored private var gapImmediateRequested = false
    @ObservationIgnored private var gapResetLogged = false
    @ObservationIgnored private var gapAttemptCount = 0
    @ObservationIgnored private var gapFetchInFlight = false
    @ObservationIgnored private var gapRequiresReset = false
    @ObservationIgnored private var hasConfirmedTotal = false
    @ObservationIgnored private var transcriptGap = false
    @ObservationIgnored private var closed = false
    private let builtFromCache: Bool
    private let cacheHasEntries: Bool
    private var readinessStateCurrent = false
    private var readinessDaemonEpoch: String?
    private var readinessServerRev: Int?
    private var readinessOffline = false
    @ObservationIgnored private var readinessDeadlineTask: Task<Void, Never>?
    private let readinessTimeout: Duration
    private var hasLoaded = false
    private var initialPageMerged = false

    private struct TranscriptFetch {
        enum Kind {
            case initial
            case refetch(origin: UUID?)
        }

        let id: UUID
        let kind: Kind
        let task: Task<TranscriptChangeSet, Error>
    }

    private struct PendingRefetch {
        var limit: Int
        var reset: Bool
        let origin: UUID
    }
    private var turnStartIndices: [Int] = []
    private var turnRows: [[TranscriptRow]] = []
    private var earlierIdentityKeys: Set<String> = []

    public convenience init(
        session: Session,
        client: APIClient,
        agentID: String? = nil,
        entries: [TranscriptEntry] = [],
        onTranscriptChange: (([TranscriptEntry]) -> Void)? = nil,
        initialTranscriptTail: Int = 100,
        transcriptOnly: Bool = false,
        serverTotal: Int? = nil,
        cachedRev: Int? = nil,
        cachedEpoch: String? = nil,
        daemonEpoch: String? = nil,
        serverRev: Int? = nil,
        isStateCurrent: Bool = false,
        isOffline: Bool = false,
        builtFromCache: Bool? = nil,
        readinessTimeout: Duration = .seconds(5),
        clock: @escaping () -> Date = Date.init
    ) {
        self.init(
            session: session,
            client: client,
            agentID: agentID,
            entries: entries,
            onTranscriptChange: onTranscriptChange,
            initialTranscriptTail: initialTranscriptTail,
            transcriptOnly: transcriptOnly,
            serverTotal: serverTotal,
            cachedRev: cachedRev,
            cachedEpoch: cachedEpoch,
            daemonEpoch: daemonEpoch,
            serverRev: serverRev,
            isStateCurrent: isStateCurrent,
            isOffline: isOffline,
            builtFromCache: builtFromCache,
            readinessTimeout: readinessTimeout,
            scheduler: SessionStoreClock(nowProvider: clock),
            internalMarker: ()
        )
    }

    init(
        session: Session,
        client: APIClient,
        agentID: String? = nil,
        entries: [TranscriptEntry] = [],
        onTranscriptChange: (([TranscriptEntry]) -> Void)? = nil,
        initialTranscriptTail: Int = 100,
        transcriptOnly: Bool = false,
        serverTotal: Int? = nil,
        cachedRev: Int? = nil,
        cachedEpoch: String? = nil,
        daemonEpoch: String? = nil,
        serverRev: Int? = nil,
        isStateCurrent: Bool = false,
        isOffline: Bool = false,
        builtFromCache: Bool? = nil,
        readinessTimeout: Duration = .seconds(5),
        scheduler: any CCKitClock = SystemCCKitClock(),
        internalMarker: Void
    ) {
        self.session = session
        self.sessionID = session.id ?? ""
        self.client = client
        self.agentID = agentID
        self.onTranscriptChange = onTranscriptChange
        self.clock = scheduler
        self.readinessTimeout = readinessTimeout
        self.initialTranscriptTail = max(1, initialTranscriptTail)
        self.transcriptOnly = transcriptOnly
        self.transcriptStore = TranscriptStore(entries: entries)
        let initialServerTotal = max(0, serverTotal ?? entries.count)
        self.serverTotal = initialServerTotal
        self.confirmedTotal = 0
        self.builtFromCache = builtFromCache ?? !entries.isEmpty
        self.cacheHasEntries = !entries.isEmpty
        self.syncedRev = cachedRev
        self.syncedEpoch = cachedEpoch
        self.readinessStateCurrent = isStateCurrent
        self.readinessDaemonEpoch = daemonEpoch
        self.readinessServerRev = serverRev
        self.readinessOffline = isOffline
        self.readinessDeadlineTask = nil
        self.hasLoaded = !entries.isEmpty
        refreshTurns(forceFull: true)
        startReadinessDeadline()
        updateReadiness()
    }

    public func updateSession(_ session: Session) {
        let wasWorking = self.session.state == .working
        self.session = session
        if session.live == true { transcriptOnly = false }
        if wasWorking != (session.state == .working) { refreshTurns(forceFull: true) }
    }

    public func updateReadiness(isStateCurrent: Bool, daemonEpoch: String?, serverRev: Int?, isOffline: Bool) {
        readinessStateCurrent = isStateCurrent
        readinessDaemonEpoch = daemonEpoch
        readinessServerRev = serverRev
        readinessOffline = isOffline
        updateReadiness()
    }

    private func updateReadiness() {
        guard readiness != .ready else { return }
        guard agentID == nil else {
            markReady()
            return
        }
        if readinessOffline || initialPageMerged ||
            (cacheHasEntries && readinessStateCurrent && readinessServerRev == nil) ||
            (builtFromCache && cacheHasEntries && readinessStateCurrent &&
             syncedEpoch != nil && syncedRev != nil &&
             syncedEpoch == readinessDaemonEpoch && syncedRev == readinessServerRev) {
            markReady()
        }
    }

    private func startReadinessDeadline() {
        readinessDeadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.readinessTimeout)
            } catch {
                return
            }
            guard self.readiness == .syncing, !self.closed else { return }
            self.readiness = .ready
            self.readinessDeadlineTask = nil
            TranscriptLifecycleLog.shared.record(name: "transcript-readiness-timeout", sessionID: self.sessionID)
        }
    }

    private func cancelReadinessDeadline() {
        readinessDeadlineTask?.cancel()
        readinessDeadlineTask = nil
    }

    private func markReady() {
        guard readiness != .ready else { return }
        readiness = .ready
        cancelReadinessDeadline()
    }

    private func markReadyAfterFailure() {
        markReady()
    }

    private func setSyncedRevision(_ rev: Int) {
        if let epoch = readinessDaemonEpoch, syncedEpoch == epoch {
            syncedRev = max(syncedRev ?? rev, rev)
        } else {
            syncedRev = rev
        }
        syncedEpoch = readinessDaemonEpoch
    }

    @discardableResult
    public func loadInitial() async throws -> TranscriptChangeSet {
        guard canFetch else { return TranscriptChangeSet() }
        if let current = inFlightTranscriptFetch {
            do {
                _ = try await awaitFetch(current, cancelUnderlying: false)
            } catch {
                finishFetch(current.id)
                guard !Task.isCancelled else { throw error }
                guard !hasLoaded else { return TranscriptChangeSet() }
                do {
                    return try await runInitialFetch()
                } catch {
                    markReadyAfterFailure()
                    markTranscriptGap(force: true)
                    requestTranscriptResync()
                    throw error
                }
            }
            finishFetch(current.id)
            if hasLoaded { return TranscriptChangeSet() }
            do {
                return try await runInitialFetch()
            } catch {
                markReadyAfterFailure()
                markTranscriptGap(force: true)
                requestTranscriptResync()
                throw error
            }
        }
        do {
            return try await runInitialFetch()
        } catch {
            markReadyAfterFailure()
            markTranscriptGap(force: true)
            requestTranscriptResync()
            throw error
        }
    }

    @discardableResult
    public func merge(_ incoming: [TranscriptEntry], replace: Bool = false, entryCount: Int? = nil, appendNewEntries: Bool = false) -> TranscriptChangeSet {
        let change = transcriptStore.merge(incoming, replace: replace, appendNewEntries: appendNewEntries)
        if let entryCount { serverTotal = max(0, entryCount) }
        else if !hasLoaded { serverTotal = max(serverTotal, transcriptStore.entries.count) }
        publish(change)
        return change
    }

    /// Merges a live event and advances completion only when the event is contiguous.
    @discardableResult
    public func mergeLive(
        _ incoming: [TranscriptEntry],
        replace: Bool = false,
        entryCount: Int?,
        rev: Int? = nil,
        wasInSync: Bool = false
    ) -> TranscriptChangeSet {
        let change = transcriptStore.merge(incoming, replace: replace, appendNewEntries: true)
        if let entryCount {
            serverTotal = max(0, entryCount)
            if hasConfirmedTotal {
                let allowedTotal = confirmedTotal + (change.inserted.isEmpty ? 0 : 1)
                if entryCount <= allowedTotal {
                    confirmedTotal = max(confirmedTotal, entryCount)
                } else {
                    markTranscriptGap()
                }
            }
        }
        if wasInSync, !hasTranscriptGap, let rev { setSyncedRevision(rev) }
        publish(change)
        return change
    }

    /// Records a count from state without claiming that the local transcript is complete.
    public func observeServerTotal(_ count: Int) {
        serverTotal = max(0, count)
        if hasConfirmedTotal, serverTotal > confirmedTotal { markTranscriptGap() }
    }

    /// Starts or wakes the single resync loop for this store.
    public func recordTranscriptResync(reason: String) {
        guard hasTranscriptGap else { return }
        TranscriptLifecycleLog.shared.recordGap(
            name: "transcript-gap-resync-requested",
            sessionID: sessionID,
            serverTotal: serverTotal,
            confirmedTotal: confirmedTotal,
            attempt: gapAttemptCount,
            errorType: reason
        )
    }

    public func requestTranscriptReset() {
        guard !closed else { return }
        syncedRev = nil
        transcriptGap = true
        gapRequiresReset = true
        gapAttemptCount = 0
        gapResetLogged = false
        requestTranscriptResync(immediate: true)
    }

    public func requestTranscriptResync(immediate: Bool = false) {
        guard !closed, hasTranscriptGap else { return }
        if let gapResyncTask {
            if immediate {
                gapImmediateRequested = true
                if !gapFetchInFlight { gapResyncTask.cancel() }
            }
            return
        }
        gapResyncTask = Task { @MainActor [weak self] in
            await self?.runTranscriptResync()
        }
    }

    public func close() {
        closed = true
        cancelReadinessDeadline()
        gapResyncTask?.cancel()
        gapResyncTask = nil
        gapImmediateRequested = false
    }

    private func publish(_ change: TranscriptChangeSet) {
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns(change: change)
            notify(change)
        }
    }

    @discardableResult
    public func refetchTail(reset: Bool = false) async throws -> TranscriptChangeSet {
        try await refetchTail(limit: reset ? 100 : 400, reset: reset)
    }

    @discardableResult
    public func refetchGap(limit: Int) async throws -> TranscriptChangeSet {
        #if CC_PERF
        PerfCounters.shared.record(.refetchGap, value: limit)
        #endif
        return try await refetchTail(limit: limit)
    }

    @discardableResult
    public func refetchTail(limit: Int, reset: Bool = false) async throws -> TranscriptChangeSet {
        #if CC_PERF
        PerfCounters.shared.record(.refetchTail, value: limit)
        #endif
        guard canFetch else { return TranscriptChangeSet() }
        let request = PendingRefetch(limit: min(400, max(1, limit)), reset: reset, origin: UUID())
        guard let current = inFlightTranscriptFetch else {
            return try await runRefetch(limit: request.limit, reset: request.reset, origin: nil)
        }

        mergePendingRefetch(limit: request.limit, reset: request.reset, origin: current.id)
        do {
            _ = try await awaitFetch(current, cancelUnderlying: false)
        } catch {
            finishFetch(current.id)
            guard !Task.isCancelled else { throw error }
        }

        if let newer = inFlightTranscriptFetch, newer.id != current.id {
            if case .refetch(let origin) = newer.kind, origin == current.id {
                return try await awaitFetch(newer, cancelUnderlying: false)
            }
            do {
                _ = try await awaitFetch(newer, cancelUnderlying: false)
            } catch {
                finishFetch(newer.id)
                guard !Task.isCancelled else { throw error }
            }
        }
        finishFetch(current.id)
        guard let followUp = pendingRefetch else { return try await runRefetch(limit: request.limit, reset: request.reset, origin: nil) }
        pendingRefetch = nil
        return try await runRefetch(limit: followUp.limit, reset: followUp.reset, origin: followUp.origin)
    }

    @discardableResult
    public func loadEarlier() async throws -> TranscriptChangeSet {
        guard canFetch, hasMoreEarlier, !loadingEarlier, inFlightTranscriptFetch == nil, let oldestID = entries.first?.id else { return TranscriptChangeSet() }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let page = try await client.transcriptPage(sessionID: sessionID, before: oldestID, limit: 200, agent: agentID)
        let change = transcriptStore.merge(page.entries)
        hasMoreEarlier = page.hasMore
        serverTotal = max(0, page.total)
        #if DEBUG
        postCCMotionTraceEvent("pageLoaded", data: ["count": change.inserted.count])
        #endif
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns(change: change, forceFull: true)
            notify(change)
        }
        return change
    }

    private func runInitialFetch() async throws -> TranscriptChangeSet {
        let ownsFetch = inFlightTranscriptFetch == nil
        let fetch = inFlightTranscriptFetch ?? startInitialFetch()
        do {
            let change = try await awaitFetch(fetch, cancelUnderlying: ownsFetch)
            finishFetch(fetch.id)
            return change
        } catch {
            finishFetch(fetch.id)
            throw error
        }
    }

    private func runRefetch(limit: Int, reset: Bool, origin: UUID?) async throws -> TranscriptChangeSet {
        let ownsFetch = inFlightTranscriptFetch == nil
        let fetch = inFlightTranscriptFetch ?? startRefetch(limit: limit, reset: reset, origin: origin)
        do {
            let change = try await awaitFetch(fetch, cancelUnderlying: ownsFetch)
            finishFetch(fetch.id)
            return change
        } catch {
            finishFetch(fetch.id)
            throw error
        }
    }

    private func startInitialFetch() -> TranscriptFetch {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performInitialFetch()
        }
        let fetch = TranscriptFetch(id: id, kind: .initial, task: task)
        inFlightTranscriptFetch = fetch
        return fetch
    }

    private func startRefetch(limit: Int, reset: Bool, origin: UUID?) -> TranscriptFetch {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performRefetch(limit: limit, reset: reset)
        }
        let fetch = TranscriptFetch(id: id, kind: .refetch(origin: origin), task: task)
        inFlightTranscriptFetch = fetch
        return fetch
    }

    private func awaitFetch(_ fetch: TranscriptFetch, cancelUnderlying: Bool) async throws -> TranscriptChangeSet {
        try await withTaskCancellationHandler {
            try await fetch.task.value
        } onCancel: {
            if cancelUnderlying { fetch.task.cancel() }
        }
    }

    private func finishFetch(_ id: UUID) {
        guard inFlightTranscriptFetch?.id == id else { return }
        inFlightTranscriptFetch = nil
    }

    private func mergePendingRefetch(limit: Int, reset: Bool, origin: UUID) {
        guard var pending = pendingRefetch else {
            pendingRefetch = PendingRefetch(limit: limit, reset: reset, origin: origin)
            return
        }
        pending.limit = max(pending.limit, limit)
        pending.reset = pending.reset || reset
        pendingRefetch = pending
    }

    private func markTranscriptGap(force: Bool = false) {
        guard force || hasConfirmedTotal else { return }
        guard serverTotal > confirmedTotal else { return }
        guard !transcriptGap else { return }
        syncedRev = nil
        transcriptGap = true
        gapAttemptCount = 0
        gapResetLogged = false
        TranscriptLifecycleLog.shared.recordGap(
            name: "transcript-gap-detected",
            sessionID: sessionID,
            serverTotal: serverTotal,
            confirmedTotal: confirmedTotal
        )
    }

    private func confirmTranscriptPage(total: Int) {
        let wasGap = hasTranscriptGap
        serverTotal = max(0, total)
        confirmedTotal = serverTotal
        hasConfirmedTotal = true
        gapRequiresReset = false
        transcriptGap = false
        if wasGap {
            TranscriptLifecycleLog.shared.recordGap(
                name: "transcript-gap-healed",
                sessionID: sessionID,
                serverTotal: serverTotal,
                confirmedTotal: confirmedTotal,
                attempt: gapAttemptCount
            )
        }
        gapAttemptCount = 0
        gapResetLogged = false
    }

    private func runTranscriptResync() async {
        var attempt = 0
        while !Task.isCancelled, !closed, hasTranscriptGap {
            if gapImmediateRequested {
                gapImmediateRequested = false
            }
            attempt += 1
            gapAttemptCount = attempt
            let missing = max(1, serverTotal - confirmedTotal)
            let reset = gapRequiresReset || missing > 400
            if missing > 400, !gapResetLogged {
                gapResetLogged = true
                TranscriptLifecycleLog.shared.recordGap(
                    name: "transcript-gap-reset",
                    sessionID: sessionID,
                    serverTotal: serverTotal,
                    confirmedTotal: confirmedTotal,
                    attempt: attempt
                )
            }
            gapFetchInFlight = true
            do {
                _ = try await refetchTail(limit: reset ? 100 : Self.gapFetchLimit(missing: missing), reset: reset)
                gapFetchInFlight = false
                if !hasTranscriptGap { break }
            } catch {
                gapFetchInFlight = false
                if Task.isCancelled, gapImmediateRequested { continue }
                guard !Task.isCancelled, !closed else { return }
                TranscriptLifecycleLog.shared.recordGap(
                    name: "transcript-gap-fetch-failed",
                    sessionID: sessionID,
                    serverTotal: serverTotal,
                    confirmedTotal: confirmedTotal,
                    attempt: attempt,
                    errorType: String(describing: type(of: error))
                )
                if gapImmediateRequested {
                    gapImmediateRequested = false
                    continue
                }
                let delay = Self.gapBackoff(attempt: attempt)
                do {
                    try await clock.sleep(for: .seconds(delay))
                } catch {
                    if gapImmediateRequested { continue }
                    return
                }
            }
        }
        let restartImmediately = gapImmediateRequested && !closed
        gapResyncTask = nil
        gapImmediateRequested = false
        if !hasTranscriptGap { gapResetLogged = false }
        if restartImmediately { requestTranscriptResync() }
    }

    private static func gapFetchLimit(missing: Int) -> Int {
        min(400, max(1, missing + 20))
    }

    private static func gapBackoff(attempt: Int) -> Double {
        min(30, pow(2, Double(max(0, attempt - 1))))
    }

    private func performInitialFetch() async throws -> TranscriptChangeSet {
        #if DEBUG || CC_PERF
        TranscriptPerformance.shared.begin(sessionID: sessionID)
        TranscriptPerformance.shared.markRequestSent()
        #endif
        let page = try await client.transcriptPage(sessionID: sessionID, tail: initialTranscriptTail, agent: agentID)
        let previousEntries = transcriptStore.entries
        let change: TranscriptChangeSet
        let replacedAll: Bool
        if !entries.isEmpty, page.entries.contains(where: { transcriptStore.containsIdentity(of: $0) }) {
            change = transcriptStore.merge(page.entries)
            replacedAll = false
        } else {
            change = transcriptStore.replaceAll(with: page.entries)
            replacedAll = true
        }
        let entriesChanged = previousEntries != transcriptStore.entries
        #if DEBUG || CC_PERF
        TranscriptPerformance.shared.markMergeDone()
        #endif
        hasMoreEarlier = transcriptStore.entries.count < page.total
        if gapRequiresReset { serverTotal = max(0, page.total) }
        else { confirmTranscriptPage(total: page.total) }
        if let rev = page.rev { setSyncedRevision(rev) }
        initialPageMerged = true
        hasLoaded = true
        updateReadiness()
        if entriesChanged {
            refreshTurns(change: change, forceFull: replacedAll)
            notify(change)
        }
        return change
    }

    private func performRefetch(limit: Int, reset: Bool) async throws -> TranscriptChangeSet {
        let page = try await client.transcriptPage(sessionID: sessionID, tail: min(400, max(1, limit)), agent: agentID)
        let change: TranscriptChangeSet
        let replacedAll: Bool
        if reset {
            change = transcriptStore.replaceAll(with: page.entries)
            replacedAll = true
            hasMoreEarlier = page.hasMore
        } else if page.entries.contains(where: { transcriptStore.containsIdentity(of: $0) }) {
            replacedAll = false
            let retained = page.entries.filter { !transcriptStore.isBeforeFirst($0) }
            change = transcriptStore.merge(retained)
        } else {
            change = transcriptStore.replaceAll(with: page.entries)
            replacedAll = true
            hasMoreEarlier = page.hasMore
        }
        if reset || !gapRequiresReset { confirmTranscriptPage(total: page.total) }
        else { serverTotal = max(0, page.total) }
        if let rev = page.rev { setSyncedRevision(rev) }
        initialPageMerged = true
        hasLoaded = true
        updateReadiness()
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns(change: change, forceFull: replacedAll)
            notify(change)
        }
        return change
    }

    public func resetTranscript() {
        TranscriptLifecycleLog.shared.record(name: "transcript-reset", sessionID: sessionID)
        #if DEBUG
        postCCMotionTraceEvent("entriesRemoved", data: ["ids": transcriptStore.entries.map { $0.id ?? "" }])
        #endif
        transcriptStore = TranscriptStore()
        turns = []
        rows = []
        turnStartIndices = []
        turnRows = []
        earlierIdentityKeys = []
        hasMoreEarlier = false
        serverTotal = 0
        confirmedTotal = 0
        gapResyncTask?.cancel()
        gapResyncTask = nil
        gapImmediateRequested = false
        gapResetLogged = false
        gapAttemptCount = 0
        gapRequiresReset = false
        hasConfirmedTotal = false
        transcriptGap = false
        syncedRev = nil
        syncedEpoch = nil
        initialPageMerged = false
        hasLoaded = false
        onTranscriptChange?([])
    }

    public var isLoaded: Bool { hasLoaded }

    private var canFetch: Bool { !sessionID.isEmpty && (session.live == true || transcriptOnly) }

    private func notify(_ change: TranscriptChangeSet) {
        #if DEBUG
        if !change.inserted.isEmpty {
            postCCMotionTraceEvent("entriesInserted", data: ["ids": change.inserted.map { $0.id ?? "" }])
        }
        if !change.updatedIDs.isEmpty {
            postCCMotionTraceEvent("entriesUpdated", data: ["ids": change.updatedIDs])
        }
        #endif
        onTranscriptChange?(change.changed)
    }

    private func refreshTurns(change: TranscriptChangeSet? = nil, forceFull: Bool = false) {
        #if CC_PERF
        PerfCounters.shared.hit(.refreshTurns)
        #endif
        let now = clock.now
        if !forceFull, let change, let startIndex = incrementalStartIndex(for: change) {
            let prefixCount = max(0, turns.count - 2)
            let suffix = Array(transcriptStore.entries[startIndex...])
            let grouped = groupTurnsWithStarts(
                entries: suffix,
                working: session.state == .working,
                now: now,
                turnIndexOffset: prefixCount
            )
            turns = Array(turns.prefix(prefixCount)) + grouped.turns
            turnRows = Array(turnRows.prefix(prefixCount)) + grouped.turns.map(transcriptRows(for:))
            rows = transcriptRows(for: turns)
            turnStartIndices = Array(turnStartIndices.prefix(prefixCount)) + grouped.startIndices.map { startIndex + $0 }
            let newPrefixCount = max(0, turns.count - 2)
            let newStartIndex = turnStartIndices.indices.contains(newPrefixCount) ? turnStartIndices[newPrefixCount] : 0
            if newStartIndex != startIndex { updateEarlierIdentityKeys() }
        } else {
            let grouped = groupTurnsWithStarts(entries: transcriptStore.entries, working: session.state == .working, now: now)
            turns = grouped.turns
            turnRows = grouped.turns.map(transcriptRows(for:))
            rows = transcriptRows(for: turns)
            turnStartIndices = grouped.startIndices
            updateEarlierIdentityKeys()
        }
        if forceFull {
            TranscriptLifecycleLog.shared.record(
                name: "turns-full-refresh",
                sessionID: sessionID,
                detail: "\(turns.count)"
            )
        }
        #if DEBUG || CC_PERF
        TranscriptPerformance.shared.markGroupingDone()
        #endif
    }

    private func incrementalStartIndex(for change: TranscriptChangeSet) -> Int? {
        let prefixCount = max(0, turns.count - 2)
        let startIndex = turnStartIndices.indices.contains(prefixCount) ? turnStartIndices[prefixCount] : 0
        let changedEntries = change.inserted + change.updated
        guard !changedEntries.isEmpty else { return nil }
        let keys = changedEntries.map(transcriptStore.identityKey(for:))
        guard !keys.contains(where: earlierIdentityKeys.contains) else { return nil }
        let tailKeys = Set(transcriptStore.entries[startIndex...].map(transcriptStore.identityKey(for:)))
        guard keys.allSatisfy(tailKeys.contains) else { return nil }
        return startIndex
    }

    private func updateEarlierIdentityKeys() {
        let prefixCount = max(0, turns.count - 2)
        let startIndex = turnStartIndices.indices.contains(prefixCount) ? turnStartIndices[prefixCount] : 0
        earlierIdentityKeys = Set(transcriptStore.entries[..<startIndex].map(transcriptStore.identityKey(for:)))
    }
}
