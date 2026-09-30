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
    @ObservationIgnored private var hasLoaded = false

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
        self.session = session
        refreshTurns()
    }

    public func loadInitial() async throws {
        guard canFetch, !loading else { return }
        loading = true
        defer { loading = false }
        let page = try await client.transcriptPage(sessionID: sessionID, tail: 400, agent: agentID)
        _ = transcriptStore.replaceAll(with: page.entries)
        hasMoreEarlier = page.hasMore
        totalEntries = page.total
        hasLoaded = true
        refreshTurns()
    }

    @discardableResult
    public func merge(_ incoming: [TranscriptEntry], replace: Bool = false) -> TranscriptChangeSet {
        let change = transcriptStore.merge(incoming, replace: replace)
        if !change.inserted.isEmpty || !change.updatedIDs.isEmpty { refreshTurns() }
        return change
    }

    public func refetchTail(reset: Bool = false) async throws {
        guard canFetch, !loading else { return }
        loading = true
        defer { loading = false }
        let page = try await client.transcriptPage(sessionID: sessionID, tail: 400, agent: agentID)
        if reset {
            _ = transcriptStore.replaceAll(with: page.entries)
        } else {
            transcriptStore.merge(page.entries)
        }
        hasMoreEarlier = page.hasMore
        totalEntries = max(totalEntries, page.total)
        hasLoaded = true
        refreshTurns()
    }

    public func loadEarlier() async throws {
        guard canFetch, hasMoreEarlier, !loadingEarlier, !loading, let oldestID = entries.first?.id else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let page = try await client.transcriptPage(sessionID: sessionID, before: oldestID, limit: 400, agent: agentID)
        transcriptStore.merge(page.entries)
        hasMoreEarlier = page.hasMore
        totalEntries = max(totalEntries, page.total)
        refreshTurns()
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
        turns = groupTranscript(entries: transcriptStore.entries, working: session.state == .working)
    }
}
