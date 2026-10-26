import Foundation
import Observation

@MainActor @Observable
public final class SessionStore {
    public let sessionID: String
    public let agentID: String?
    public private(set) var session: Session
    public private(set) var transcriptStore: TranscriptStore
    public private(set) var turns: [Turn] = []
    public private(set) var rows: [TranscriptRow] = []
    public private(set) var hasMoreEarlier = false
    public private(set) var totalEntries = 0
    public var entries: [TranscriptEntry] { transcriptStore.entries }

    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let onTranscriptChange: (([TranscriptEntry]) -> Void)?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let initialTranscriptTail: Int
    @ObservationIgnored private var loadingEarlier = false
    @ObservationIgnored private var inFlightTranscriptFetch: TranscriptFetch?
    @ObservationIgnored private var pendingRefetch: PendingRefetch?
    private var hasLoaded = false

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
        initialTranscriptTail: Int = 100
    ) {
        self.init(
            session: session,
            client: client,
            agentID: agentID,
            entries: entries,
            onTranscriptChange: onTranscriptChange,
            initialTranscriptTail: initialTranscriptTail,
            clock: Date.init
        )
    }

    init(
        session: Session,
        client: APIClient,
        agentID: String? = nil,
        entries: [TranscriptEntry] = [],
        onTranscriptChange: (([TranscriptEntry]) -> Void)? = nil,
        initialTranscriptTail: Int = 100,
        clock: @escaping () -> Date
    ) {
        self.session = session
        self.sessionID = session.id ?? ""
        self.client = client
        self.agentID = agentID
        self.onTranscriptChange = onTranscriptChange
        self.clock = clock
        self.initialTranscriptTail = max(1, initialTranscriptTail)
        self.transcriptStore = TranscriptStore(entries: entries)
        self.totalEntries = entries.count
        self.hasLoaded = !entries.isEmpty
        refreshTurns(forceFull: true)
    }

    public func updateSession(_ session: Session) {
        let wasWorking = self.session.state == .working
        self.session = session
        if wasWorking != (session.state == .working) { refreshTurns(forceFull: true) }
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
                return try await runInitialFetch()
            }
            finishFetch(current.id)
            if hasLoaded { return TranscriptChangeSet() }
            return try await runInitialFetch()
        }
        return try await runInitialFetch()
    }

    @discardableResult
    public func merge(_ incoming: [TranscriptEntry], replace: Bool = false, entryCount: Int? = nil, appendNewEntries: Bool = false) -> TranscriptChangeSet {
        let change = transcriptStore.merge(incoming, replace: replace, appendNewEntries: appendNewEntries)
        if let entryCount { totalEntries = max(totalEntries, entryCount) }
        else if !hasLoaded { totalEntries = max(totalEntries, transcriptStore.entries.count) }
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns(change: change)
            notify(change)
        }
        return change
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
        totalEntries = max(totalEntries, page.total)
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
        totalEntries = page.total
        hasLoaded = true
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
        totalEntries = max(totalEntries, page.total)
        hasLoaded = true
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns(change: change, forceFull: replacedAll)
            notify(change)
        }
        return change
    }

    public func resetTranscript() {
        TranscriptLifecycleLog.shared.record(name: "transcript-reset", sessionID: sessionID)
        transcriptStore = TranscriptStore()
        turns = []
        rows = []
        turnStartIndices = []
        turnRows = []
        earlierIdentityKeys = []
        hasMoreEarlier = false
        totalEntries = 0
        hasLoaded = false
        onTranscriptChange?([])
    }

    public var isLoaded: Bool { hasLoaded }

    private var canFetch: Bool { session.live == true && !sessionID.isEmpty }

    private func notify(_ change: TranscriptChangeSet) {
        onTranscriptChange?(change.changed)
    }

    private func refreshTurns(change: TranscriptChangeSet? = nil, forceFull: Bool = false) {
        #if CC_PERF
        PerfCounters.shared.hit(.refreshTurns)
        #endif
        let now = clock()
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
            rows = turnRows.flatMap { $0 }
            turnStartIndices = Array(turnStartIndices.prefix(prefixCount)) + grouped.startIndices.map { startIndex + $0 }
            let newPrefixCount = max(0, turns.count - 2)
            let newStartIndex = turnStartIndices.indices.contains(newPrefixCount) ? turnStartIndices[newPrefixCount] : 0
            if newStartIndex != startIndex { updateEarlierIdentityKeys() }
        } else {
            let grouped = groupTurnsWithStarts(entries: transcriptStore.entries, working: session.state == .working, now: now)
            turns = grouped.turns
            turnRows = grouped.turns.map(transcriptRows(for:))
            rows = turnRows.flatMap { $0 }
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
