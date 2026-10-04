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
    @ObservationIgnored private var loadingEarlier = false
    @ObservationIgnored private var loading = false
    private var hasLoaded = false

    public init(
        session: Session,
        client: APIClient,
        agentID: String? = nil,
        entries: [TranscriptEntry] = []
    ) {
        self.session = session
        self.sessionID = session.id ?? ""
        self.client = client
        self.agentID = agentID
        self.transcriptStore = TranscriptStore(entries: entries)
        self.totalEntries = entries.count
        refreshTurns()
    }

    public func updateSession(_ session: Session) {
        let wasWorking = self.session.state == .working
        self.session = session
        if wasWorking != (session.state == .working) { refreshTurns() }
    }

    public func loadInitial() async throws {
        guard canFetch, !loading else { return }
        loading = true
        defer { loading = false }
        #if DEBUG
        TranscriptPerformance.shared.begin(sessionID: sessionID)
        TranscriptPerformance.shared.markRequestSent()
        #endif
        let page = try await client.transcriptPage(sessionID: sessionID, tail: 100, agent: agentID)
        _ = transcriptStore.replaceAll(with: page.entries)
        #if DEBUG
        TranscriptPerformance.shared.markMergeDone()
        #endif
        hasMoreEarlier = page.hasMore
        totalEntries = page.total
        hasLoaded = true
        refreshTurns()
    }

    @discardableResult
    public func merge(_ incoming: [TranscriptEntry], replace: Bool = false, entryCount: Int? = nil, appendNewEntries: Bool = false) -> TranscriptChangeSet {
        let change = transcriptStore.merge(incoming, replace: replace, appendNewEntries: appendNewEntries)
        if let entryCount { totalEntries = max(totalEntries, entryCount) }
        else if !hasLoaded { totalEntries = max(totalEntries, transcriptStore.entries.count) }
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty { refreshTurns() }
        return change
    }

    public func refetchTail(reset: Bool = false) async throws {
        try await refetchTail(limit: 400, reset: reset)
    }

    public func refetchGap(limit: Int) async throws {
        #if CC_PERF
        PerfCounters.shared.record(.refetchGap, value: limit)
        #endif
        try await refetchTail(limit: limit)
    }

    public func refetchTail(limit: Int, reset: Bool = false) async throws {
        #if CC_PERF
        PerfCounters.shared.record(.refetchTail, value: limit)
        #endif
        guard canFetch, !loading else { return }
        loading = true
        defer { loading = false }
        let page = try await client.transcriptPage(sessionID: sessionID, tail: min(400, max(1, limit)), agent: agentID)
        let change: TranscriptChangeSet
        if reset {
            change = transcriptStore.replaceAll(with: page.entries)
        } else {
            change = transcriptStore.merge(page.entries)
        }
        hasMoreEarlier = page.hasMore
        totalEntries = max(totalEntries, page.total)
        hasLoaded = true
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty { refreshTurns() }
    }

    public func loadEarlier() async throws {
        guard canFetch, hasMoreEarlier, !loadingEarlier, !loading, let oldestID = entries.first?.id else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let page = try await client.transcriptPage(sessionID: sessionID, before: oldestID, limit: 200, agent: agentID)
        let change = transcriptStore.merge(page.entries)
        hasMoreEarlier = page.hasMore
        totalEntries = max(totalEntries, page.total)
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty { refreshTurns() }
    }

    public func resetTranscript() {
        transcriptStore = TranscriptStore()
        turns = []
        hasMoreEarlier = false
        totalEntries = 0
        hasLoaded = false
    }

    public var isLoaded: Bool { hasLoaded }

    private var canFetch: Bool { session.live == true && !sessionID.isEmpty }

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
