import Foundation
import Observation

@MainActor @Observable
public final class SessionStore {
    public let sessionID: String
    public let agentID: String?
    public private(set) var session: Session
    public private(set) var transcriptStore: TranscriptStore
    public private(set) var turns: [Turn] = []
    public private(set) var hasMoreEarlier = false
    public private(set) var totalEntries = 0
    public var entries: [TranscriptEntry] { transcriptStore.entries }

    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let onTranscriptChange: (([TranscriptEntry]) -> Void)?
    @ObservationIgnored private var loadingEarlier = false
    @ObservationIgnored private var loading = false
    private var hasLoaded = false

    public init(
        session: Session,
        client: APIClient,
        agentID: String? = nil,
        entries: [TranscriptEntry] = [],
        onTranscriptChange: (([TranscriptEntry]) -> Void)? = nil
    ) {
        self.session = session
        self.sessionID = session.id ?? ""
        self.client = client
        self.agentID = agentID
        self.onTranscriptChange = onTranscriptChange
        self.transcriptStore = TranscriptStore(entries: entries)
        self.totalEntries = entries.count
        self.hasLoaded = !entries.isEmpty
        refreshTurns()
    }

    public func updateSession(_ session: Session) {
        let wasWorking = self.session.state == .working
        self.session = session
        if wasWorking != (session.state == .working) { refreshTurns() }
    }

    @discardableResult
    public func loadInitial() async throws -> TranscriptChangeSet {
        guard canFetch, !loading else { return TranscriptChangeSet() }
        loading = true
        defer { loading = false }
        #if DEBUG
        TranscriptPerformance.shared.begin(sessionID: sessionID)
        TranscriptPerformance.shared.markRequestSent()
        #endif
        let page = try await client.transcriptPage(sessionID: sessionID, tail: 100, agent: agentID)
        let previousEntries = transcriptStore.entries
        let change: TranscriptChangeSet
        if !entries.isEmpty, page.entries.contains(where: { transcriptStore.containsIdentity(of: $0) }) {
            change = transcriptStore.merge(page.entries)
        } else {
            change = transcriptStore.replaceAll(with: page.entries)
        }
        let entriesChanged = previousEntries != transcriptStore.entries
        #if DEBUG
        TranscriptPerformance.shared.markMergeDone()
        #endif
        hasMoreEarlier = transcriptStore.entries.count < page.total
        totalEntries = page.total
        hasLoaded = true
        if entriesChanged {
            refreshTurns()
            notify(change)
        }
        return change
    }

    @discardableResult
    public func merge(_ incoming: [TranscriptEntry], replace: Bool = false, entryCount: Int? = nil, appendNewEntries: Bool = false) -> TranscriptChangeSet {
        let change = transcriptStore.merge(incoming, replace: replace, appendNewEntries: appendNewEntries)
        if let entryCount { totalEntries = max(totalEntries, entryCount) }
        else if !hasLoaded { totalEntries = max(totalEntries, transcriptStore.entries.count) }
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns()
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
        guard canFetch, !loading else { return TranscriptChangeSet() }
        loading = true
        defer { loading = false }
        let page = try await client.transcriptPage(sessionID: sessionID, tail: min(400, max(1, limit)), agent: agentID)
        let change: TranscriptChangeSet
        if reset {
            change = transcriptStore.replaceAll(with: page.entries)
            hasMoreEarlier = page.hasMore
        } else if page.entries.contains(where: { transcriptStore.containsIdentity(of: $0) }) {
            let retained = page.entries.filter { !transcriptStore.isBeforeFirst($0) }
            change = transcriptStore.merge(retained)
        } else {
            change = transcriptStore.replaceAll(with: page.entries)
            hasMoreEarlier = page.hasMore
        }
        totalEntries = max(totalEntries, page.total)
        hasLoaded = true
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns()
            notify(change)
        }
        return change
    }

    @discardableResult
    public func loadEarlier() async throws -> TranscriptChangeSet {
        guard canFetch, hasMoreEarlier, !loadingEarlier, !loading, let oldestID = entries.first?.id else { return TranscriptChangeSet() }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let page = try await client.transcriptPage(sessionID: sessionID, before: oldestID, limit: 200, agent: agentID)
        let change = transcriptStore.merge(page.entries)
        hasMoreEarlier = page.hasMore
        totalEntries = max(totalEntries, page.total)
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty {
            refreshTurns()
            notify(change)
        }
        return change
    }

    public func resetTranscript() {
        transcriptStore = TranscriptStore()
        turns = []
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

    private func refreshTurns() {
        #if CC_PERF
        PerfCounters.shared.hit(.refreshTurns)
        #endif
        turns = groupTranscript(entries: transcriptStore.entries, working: session.state == .working)
        #if DEBUG
        TranscriptPerformance.shared.markGroupingDone()
        #endif
    }
}
