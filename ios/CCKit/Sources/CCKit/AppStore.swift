import Foundation
import Observation
import OSLog

#if DEBUG
private let appLogger = Logger(subsystem: "com.example.cc-controller", category: "app")
#endif

private func subagentIdentity(_ value: Subagent) -> String? {
    value.toolUseId ?? value.agentId
}

@MainActor @Observable
public final class AppStore {
    static let cacheWriteDebounce: Duration = .seconds(30)
    public private(set) var connection: ConnectionState = .offline(lastUpdated: nil, error: nil)
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var previousSessionsForReplacement: [String: Session] = [:]
    public private(set) var previousSessionsForReplacementAt: Date?
    public private(set) var sleeping: [SleepingSession] = []
    public private(set) var approvals: [Approval] = []
    public private(set) var daemon: DaemonInfo?
    public private(set) var controllerInfo: ControllerInfo
    public private(set) var apiVersion: Int?
    public private(set) var lastUpdated: Date?
    public private(set) var unknownEventCount = 0
    public private(set) var deciding: Set<String> = []
    public private(set) var queuedNotes: [String: [QueuedNote]] = [:]
    public private(set) var attachments: [String: [AttachmentItem]] = [:]
    public private(set) var attachmentNotices: [String: String] = [:]
    public private(set) var attachmentRevision = 0
    public private(set) var draftRevisions: [String: Int] = [:]
    @ObservationIgnored private var drafts: [String: String] = [:]
    private var attachmentProgressDates: [String: Date] = [:]
    private var debugAttachmentSessions: Set<String> = []

    public var sortedSessions: [Session] {
        let priority: (Session) -> Int = { session in
            switch sessionActivity(session) {
            case .needsYou: 0
            case .working, .background: 1
            case .idle: 2
            }
        }
        return sessions.values.sorted { left, right in
            let leftPriority = priority(left)
            let rightPriority = priority(right)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return activityDate(left) > activityDate(right)
        }
    }

    public var needsYouSessions: [Session] { sortedSessions.filter { sessionActivity($0) == .needsYou } }
    public var workingSessions: [Session] {
        sortedSessions.filter {
            switch sessionActivity($0) {
            case .working, .background: true
            case .needsYou, .idle: false
            }
        }
    }
    public var idleSessions: [Session] { sortedSessions.filter { sessionActivity($0) == .idle } }

    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let transport: ConnectionRouter
    @ObservationIgnored private let bearerProvider: @Sendable () async throws -> String
    @ObservationIgnored private let clock: any CCKitClock
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let draftCache: DraftCache
    @ObservationIgnored private let queuedNoteCache: QueuedNoteCache
    @ObservationIgnored private let uploadTimeout: TimeInterval
    @ObservationIgnored private let initialTranscriptTail: Int
    @ObservationIgnored private let authenticationFailureHandler: (@Sendable () async -> Void)?
    @ObservationIgnored private var eventStream: EventStream?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var unknownTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationFailureTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var latestBootstrap: Bootstrap?
    @ObservationIgnored private var serverEntryCounts: [String: Int] = [:]
    @ObservationIgnored private var openStores: [String: SessionStore] = [:]
    @ObservationIgnored private var cachedTranscripts: [String: [TranscriptEntry]] = [:]
    @ObservationIgnored private var cacheChangedStoreKeys: Set<String> = []
    @ObservationIgnored private var reconnectSince: Date?
    @ObservationIgnored private let eventCoalescer = LiveEventCoalescer()
    @ObservationIgnored private var eventCoalescingTask: Task<Void, Never>?
    @ObservationIgnored private var cacheWriteTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cacheWritePending = false

    public convenience init(
        serverURL: URL,
        bearerProvider: @escaping @Sendable () async throws -> String,
        session: URLSession = .shared,
        clock: any CCKitClock = SystemCCKitClock(),
        cacheDirectory: URL,
        uploadTimeout: TimeInterval = 30,
        authenticationFailureHandler: (@Sendable () async -> Void)? = nil,
        initialTranscriptTail: Int = 100,
        controllerInfo: ControllerInfo? = nil
    ) {
        self.init(
            connection: ConnectionRouter(baseURL: serverURL, session: session),
            bearerProvider: bearerProvider,
            clock: clock,
            cacheDirectory: cacheDirectory,
            uploadTimeout: uploadTimeout,
            authenticationFailureHandler: authenticationFailureHandler,
            initialTranscriptTail: initialTranscriptTail,
            controllerInfo: controllerInfo
        )
    }

    public convenience init(
        connection: ConnectionRouter,
        bearerProvider: @escaping @Sendable () async throws -> String,
        clock: any CCKitClock = SystemCCKitClock(),
        cacheDirectory: URL,
        uploadTimeout: TimeInterval = 30,
        authenticationFailureHandler: (@Sendable () async -> Void)? = nil,
        initialTranscriptTail: Int = 100,
        controllerInfo: ControllerInfo? = nil
    ) {
        self.init(
            client: APIClient(connection: connection),
            bearerProvider: bearerProvider,
            clock: clock,
            cacheDirectory: cacheDirectory,
            uploadTimeout: uploadTimeout,
            authenticationFailureHandler: authenticationFailureHandler,
            initialTranscriptTail: initialTranscriptTail,
            controllerInfo: controllerInfo
        )
    }

    public init(
        client: APIClient,
        bearerProvider: @escaping @Sendable () async throws -> String,
        clock: any CCKitClock = SystemCCKitClock(),
        cacheDirectory: URL,
        uploadTimeout: TimeInterval = 30,
        authenticationFailureHandler: (@Sendable () async -> Void)? = nil,
        initialTranscriptTail: Int = 100,
        controllerInfo: ControllerInfo? = nil
    ) {
        self.transport = client.connection
        self.client = client
        self.bearerProvider = bearerProvider
        self.clock = clock
        self.cache = DiskCache(directory: cacheDirectory, clock: clock)
        self.draftCache = DraftCache(directory: cacheDirectory, clock: clock)
        self.queuedNoteCache = QueuedNoteCache(directory: cacheDirectory, clock: clock)
        self.drafts = (try? DraftCache.loadSync(directory: cacheDirectory)) ?? [:]
        self.queuedNotes = (try? QueuedNoteCache.loadSync(directory: cacheDirectory, now: clock.now)) ?? [:]
        self.uploadTimeout = uploadTimeout
        self.initialTranscriptTail = max(1, initialTranscriptTail)
        self.authenticationFailureHandler = authenticationFailureHandler
        self.controllerInfo = controllerInfo ?? ControllerInfo(id: .mac, name: "Mac", kind: .claudeCode, capabilities: ControllerCapability.all)
    }

    public func start() {
        guard !started else { return }
        started = true
        connection = .connecting
        authenticationFailureTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.client.authenticationFailures {
                guard let handler = self.authenticationFailureHandler else { continue }
                await handler()
            }
        }
        lifecycleTask = Task { [weak self] in
            await self?.connectInitially()
        }
    }

    public func suspend() {
        flushPendingEvents()
        flushCacheImmediately()
        draftCache.saveNow(drafts)
        deliveryTasks.values.forEach { $0.cancel() }
        deliveryTasks.removeAll()
        queuedNoteCache.saveNow(queuedNotes)
        started = false
        lifecycleTask?.cancel()
        lifecycleTask = nil
        eventTask?.cancel()
        statusTask?.cancel()
        unknownTask?.cancel()
        authenticationFailureTask?.cancel()
        eventTask = nil
        statusTask = nil
        unknownTask = nil
        authenticationFailureTask = nil
        if let eventStream {
            Task { await eventStream.stop() }
        }
        eventStream = nil
        connection = .offline(lastUpdated: lastUpdated, error: nil)
    }

    public func resume() {
        suspend()
        start()
        for sessionID in queuedNotes.keys where queuedNotes[sessionID]?.contains(where: { $0.state == .sending }) == true {
            startDeliveryWorker(for: sessionID)
        }
    }

    public func openSession(_ id: String) -> SessionStore? {
        openStore(sessionID: id, agentID: nil)
    }

    public func openSubagent(sessionID: String, agentID: String) -> SessionStore? {
        openStore(sessionID: sessionID, agentID: agentID)
    }

    public func closeSession(_ id: String) {
        closeStore(forKey: id)
    }

    public func newSessionOptions() async throws -> NewSessionOptions {
        try await client.newSessionOptions()
    }

    public func createSession(
        cwd: String,
        name: String? = nil,
        model: String? = nil,
        defaultModel: String = "default",
        prompt: String? = nil
    ) async throws -> CreatedSession {
        try await client.createSession(
            cwd: cwd,
            name: name,
            model: model == defaultModel ? nil : model,
            prompt: prompt
        )
    }

    public func waitForSession(_ id: String, timeout: Duration = .seconds(10)) async -> Bool {
        guard !id.isEmpty else { return false }
        if sessions[id] != nil { return true }
        let components = timeout.components
        let timeoutSeconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var nextStateFetch = Date.distantPast
        while Date() < deadline {
            if sessions[id] != nil { return true }
            if Date() >= nextStateFetch {
                if let snapshot = try? await client.state() {
                    applyState(snapshot)
                    if sessions[id] != nil { return true }
                }
                nextStateFetch = Date().addingTimeInterval(1)
            }
            if sessions[id] != nil { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do { try await Task.sleep(for: .milliseconds(min(100, max(1, Int(remaining * 1000))))) }
            catch { return false }
        }
        return sessions[id] != nil
    }

    public func wakeSession(id: String) async throws -> Bool {
        let response = try await client.wakeSession(id: id)
        return await waitForSession(response.id)
    }

    public func closeSubagent(sessionID: String, agentID: String) {
        closeStore(forKey: "\(sessionID)|\(agentID)")
    }

    public func approvals(for sessionID: String) -> [Approval] {
        approvals.filter { $0.sessionId == sessionID }
    }

    public func queuedNotes(for sessionID: String) -> [QueuedNote] {
        queuedNotes[sessionID] ?? []
    }

    public func draft(for sessionID: String, agentID: String? = nil) -> String {
        drafts[draftKey(sessionID: sessionID, agentID: agentID)] ?? ""
    }

    public func draftRevision(for sessionID: String, agentID: String? = nil) -> Int {
        draftRevisions[draftKey(sessionID: sessionID, agentID: agentID)] ?? 0
    }

    public func setDraft(_ text: String, for sessionID: String, agentID: String? = nil) {
        let key = draftKey(sessionID: sessionID, agentID: agentID)
        if text.isEmpty { drafts.removeValue(forKey: key) }
        else { drafts[key] = text }
        draftCache.save(drafts)
    }

    public func clearDraft(for sessionID: String, agentID: String? = nil) {
        let key = draftKey(sessionID: sessionID, agentID: agentID)
        guard drafts.removeValue(forKey: key) != nil else { return }
        draftCache.save(drafts)
    }

    private func clearDraft(for sessionID: String, matching sentText: String, agentID: String? = nil) {
        let key = draftKey(sessionID: sessionID, agentID: agentID)
        guard let current = drafts[key],
              current.trimmingCharacters(in: .whitespacesAndNewlines)
                  == sentText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        drafts.removeValue(forKey: key)
        draftCache.save(drafts)
    }

    public func allow(_ approval: Approval, scope: ApprovalScope = .once) async -> Result<Void, ActionError> {
        await decide(approval, behavior: scope == .session ? .allowSession : .allow)
    }

    public func deny(_ approval: Approval) async -> Result<Void, ActionError> {
        await decide(approval, behavior: .deny)
    }

    public func send(
        text: String,
        attachments: [String] = [],
        attachmentThumbnails: [String: Data] = [:],
        to sessionID: String,
        now: Bool = false
    ) async -> Result<Void, ActionError> {
        switch await sendResult(text: text, attachments: attachments, attachmentThumbnails: attachmentThumbnails, to: sessionID, now: now) {
        case .success: return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    public func sendResult(
        text: String,
        attachments: [String] = [],
        attachmentThumbnails: [String: Data] = [:],
        to sessionID: String,
        now: Bool = false
    ) async -> Result<MessageResult, ActionError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalid("Message text is required.")) }
        let createdAt = clock.now
        do {
            let result = try await client.message(sessionID: sessionID, text: trimmed, files: attachments, now: now)
            let isCommand = attachments.isEmpty && isSlashCommand(trimmed)
            if !isCommand {
                queuedNotes[sessionID, default: []].append(
                    QueuedNote(
                        text: trimmed,
                        state: result.queued == true ? .queued : .sent,
                        createdAt: createdAt,
                        sentAt: clock.now,
                        now: now,
                        attachments: attachments,
                        attachmentThumbnails: attachmentThumbnails
                    )
                )
                persistQueuedNotes()
                if let store = openStores[storeKey(sessionID: sessionID, agentID: nil)] {
                    reconcileQueuedNotes(for: sessionID, changedEntries: store.entries)
                }
            }
            return .success(result)
        } catch {
            return .failure(actionError(for: error))
        }
    }

    public func attachments(for sessionID: String) -> [AttachmentItem] {
        attachments[sessionID] ?? []
    }

    @discardableResult
    public func addAttachment(_ file: UploadFile, to sessionID: String) -> AttachmentItem? {
        guard attachments(for: sessionID).count < 10 else {
            attachmentNotices[sessionID] = "At most 10 attachments per message."
            return nil
        }
        let item = AttachmentItem(file: file)
        attachments[sessionID, default: []].append(item)
        attachmentRevision += 1
        attachmentNotices.removeValue(forKey: sessionID)
        if file.data.count > uploadLimit {
            updateAttachment(item.id, sessionID: sessionID) { $0.state = .failed(.tooLarge(fileName: file.name, limitBytes: self.uploadLimit)) }
            return item
        }
        startAttachmentUpload(item, sessionID: sessionID)
        return item
    }

    public func addDebugAttachments(_ urls: [URL], to sessionID: String) {
        guard !debugAttachmentSessions.contains(sessionID) else { return }
        debugAttachmentSessions.insert(sessionID)
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mimeType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
            addAttachment(AttachmentNormalizer.prepareFile(data: data, name: url.lastPathComponent, mimeType: mimeType), to: sessionID)
        }
    }

    public func removeAttachment(id: String, from sessionID: String) {
        attachments[sessionID]?.removeAll { $0.id == id }
        if attachments[sessionID]?.isEmpty == true { attachments.removeValue(forKey: sessionID) }
        attachmentProgressDates.removeValue(forKey: id)
        attachmentRevision += 1
    }

    public func retryAttachment(id: String, sessionID: String) {
        guard let item = attachments(for: sessionID).first(where: { $0.id == id }),
              item.isRetryableFailure else { return }
        attachmentProgressDates.removeValue(forKey: item.id)
        updateAttachment(item.id, sessionID: sessionID) { $0.state = .uploading(progress: 0) }
        startAttachmentUpload(item, sessionID: sessionID)
    }

    public func sendComposer(text: String, to sessionID: String, now: Bool = false) async -> Result<MessageResult, ActionError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = attachments(for: sessionID)
        guard !trimmed.isEmpty || !pending.isEmpty else { return .failure(.invalid("Message text is required.")) }
        if let caption = AttachmentItem.sendBlockedCaption(for: pending) {
            return .failure(.invalid(caption))
        }
        let pendingIDs = Set(pending.map(\.id))
        while attachments(for: sessionID).contains(where: { pendingIDs.contains($0.id) && isUploading($0) }) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let finished = attachments(for: sessionID).filter { pendingIDs.contains($0.id) }
        if let caption = AttachmentItem.sendBlockedCaption(for: finished) {
            return .failure(.invalid(caption))
        }
        let sentIDs = Set(finished.compactMap { item -> String? in
            guard case .attached = item.state else { return nil }
            return item.id
        })
        let names = finished.compactMap { item -> String? in
            guard case .attached(let file) = item.state else { return nil }
            return file.name
        }
        let thumbnails = finished.reduce(into: [String: Data]()) { result, item in
            guard item.isImage,
                  case .attached(let file) = item.state,
                  let name = file.name,
                  let data = item.thumbnailData else { return }
            result[name] = data
        }
        let result = await sendResult(
            text: trimmed.isEmpty ? "See attached." : trimmed,
            attachments: names,
            attachmentThumbnails: thumbnails,
            to: sessionID,
            now: now
        )
        if case .success = result {
            attachments[sessionID]?.removeAll { sentIDs.contains($0.id) }
            attachmentProgressDates = attachmentProgressDates.filter { !sentIDs.contains($0.key) }
            if attachments[sessionID]?.isEmpty == true { attachments.removeValue(forKey: sessionID) }
            attachmentRevision += 1
            clearDraft(for: sessionID, matching: trimmed)
        }
        return result
    }

    /// Adds a non-command message locally, then delivers it in the background.
    @discardableResult
    public func enqueueMessage(text: String, to sessionID: String, now: Bool = false) async -> Result<QueuedNote, ActionError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = attachments(for: sessionID)
        guard !trimmed.isEmpty || !pending.isEmpty else { return .failure(.invalid("Message text is required.")) }
        guard !isSlashCommand(trimmed) else { return .failure(.invalid("Slash commands must use sendComposer.")) }
        if let caption = AttachmentItem.sendBlockedCaption(for: pending) {
            return .failure(.invalid(caption))
        }
        let pendingIDs = Set(pending.map(\.id))
        while attachments(for: sessionID).contains(where: { pendingIDs.contains($0.id) && isUploading($0) }) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let finished = attachments(for: sessionID).filter { pendingIDs.contains($0.id) }
        if let caption = AttachmentItem.sendBlockedCaption(for: finished) {
            return .failure(.invalid(caption))
        }
        let sentIDs = Set(finished.compactMap { item -> String? in
            guard case .attached = item.state else { return nil }
            return item.id
        })
        let names = finished.compactMap { item -> String? in
            guard case .attached(let file) = item.state else { return nil }
            return file.name
        }
        let thumbnails = finished.reduce(into: [String: Data]()) { result, item in
            guard item.isImage,
                  case .attached(let file) = item.state,
                  let name = file.name,
                  let data = item.thumbnailData else { return }
            result[name] = data
        }
        let note = QueuedNote(
            text: trimmed.isEmpty ? "See attached." : trimmed,
            state: .sending,
            createdAt: clock.now,
            now: now,
            attachments: names,
            attachmentThumbnails: thumbnails
        )
        queuedNotes[sessionID, default: []].append(note)
        queuedNotes[sessionID] = orderedNotes(queuedNotes[sessionID] ?? [])
        attachments[sessionID]?.removeAll { sentIDs.contains($0.id) }
        attachmentProgressDates = attachmentProgressDates.filter { !sentIDs.contains($0.key) }
        if attachments[sessionID]?.isEmpty == true { attachments.removeValue(forKey: sessionID) }
        attachmentRevision += 1
        clearDraft(for: sessionID, matching: trimmed)
        persistQueuedNotes()
        startDeliveryWorker(for: sessionID)
        return .success(note)
    }

    @discardableResult
    public func retryNote(id: String, sessionID: String) -> Bool {
        guard var notes = queuedNotes[sessionID], let index = notes.firstIndex(where: { $0.id == id }), case .failed = notes[index].state else { return false }
        notes[index].state = .sending
        notes[index].sentAt = nil
        notes = orderedNotes(notes)
        queuedNotes[sessionID] = notes
        persistQueuedNotes()
        startDeliveryWorker(for: sessionID)
        return true
    }

    @discardableResult
    public func editNote(id: String, sessionID: String) -> Bool {
        guard let note = queuedNotes[sessionID]?.first(where: { $0.id == id }) else { return false }
        queuedNotes[sessionID]?.removeAll { $0.id == id }
        if queuedNotes[sessionID]?.isEmpty == true { queuedNotes.removeValue(forKey: sessionID) }
        let existingDraft = draft(for: sessionID)
        setDraft(existingDraft.isEmpty ? note.text : "\(note.text)\n\n\(existingDraft)", for: sessionID)
        restoreAttachments(from: note, to: sessionID)
        draftRevisions[draftKey(sessionID: sessionID, agentID: nil), default: 0] += 1
        queuedNoteCache.saveNow(queuedNotes)
        return true
    }

    @discardableResult
    public func deleteNote(id: String, sessionID: String) -> Bool {
        guard queuedNotes[sessionID]?.contains(where: { $0.id == id }) == true else { return false }
        queuedNotes[sessionID]?.removeAll { $0.id == id }
        if queuedNotes[sessionID]?.isEmpty == true { queuedNotes.removeValue(forKey: sessionID) }
        queuedNoteCache.saveNow(queuedNotes)
        return true
    }

    @discardableResult
    public func sendAgain(id: String, sessionID: String) -> QueuedNote? {
        guard var notes = queuedNotes[sessionID], let index = notes.firstIndex(where: { $0.id == id }), notes[index].state == .sent else { return nil }
        let old = notes.remove(at: index)
        let note = QueuedNote(
            text: old.text,
            state: .sending,
            forceSent: old.forceSent,
            createdAt: clock.now,
            now: old.now,
            attachments: old.attachments,
            attachmentThumbnails: old.attachmentThumbnails
        )
        notes.append(note)
        notes = orderedNotes(notes)
        queuedNotes[sessionID] = notes
        persistQueuedNotes()
        startDeliveryWorker(for: sessionID)
        return note
    }

    private func restoreAttachments(from note: QueuedNote, to sessionID: String) {
        guard !note.attachments.isEmpty else { return }
        let existingNames = Set(attachments(for: sessionID).map(\.name))
        let restored = note.attachments.compactMap { name -> AttachmentItem? in
            guard !existingNames.contains(name) else { return nil }
            let thumbnail = note.attachmentThumbnails[name]
            let file = UploadFile(name: name, data: thumbnail ?? Data(), isImage: thumbnail != nil, thumbnailData: thumbnail)
            return AttachmentItem(file: file, state: .attached(UploadedFile(name: name)))
        }
        guard !restored.isEmpty else { return }
        attachments[sessionID, default: []].append(contentsOf: restored)
        attachmentRevision += 1
    }

    private func orderedNotes(_ notes: [QueuedNote]) -> [QueuedNote] {
        notes.enumerated().sorted { left, right in
            if left.element.createdAt != right.element.createdAt { return left.element.createdAt < right.element.createdAt }
            return left.offset < right.offset
        }.map(\.element)
    }

    private func persistQueuedNotes() {
        queuedNoteCache.save(queuedNotes)
    }

    private func startDeliveryWorker(for sessionID: String) {
        guard deliveryTasks[sessionID] == nil else { return }
        deliveryTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let note = self.orderedNotes(self.queuedNotes[sessionID]?.filter({ $0.state == .sending }) ?? []).first else { break }
                do {
                    let result = try await self.client.message(
                        sessionID: sessionID,
                        text: note.text,
                        files: note.attachments,
                        now: note.now,
                        clientMessageId: note.id
                    )
                    guard !Task.isCancelled else { return }
                    self.markDeliverySucceeded(noteID: note.id, sessionID: sessionID, queued: result.queued == true)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.markDeliveryFailed(noteID: note.id, sessionID: sessionID, message: self.actionError(for: error).userMessage)
                }
            }
            self.deliveryTasks.removeValue(forKey: sessionID)
        }
    }

    private func markDeliverySucceeded(noteID: String, sessionID: String, queued: Bool) {
        guard var notes = queuedNotes[sessionID], let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].state = queued ? .queued : .sent
        notes[index].sentAt = clock.now
        queuedNotes[sessionID] = notes
        persistQueuedNotes()
        if let store = openStores[storeKey(sessionID: sessionID, agentID: nil)] {
            reconcileQueuedNotes(for: sessionID, changedEntries: store.entries)
        }
    }

    private func markDeliveryFailed(noteID: String, sessionID: String, message: String) {
        guard var notes = queuedNotes[sessionID], let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].state = .failed(message: message)
        notes[index].sentAt = nil
        let failureIndex = index
        for laterIndex in notes.indices where laterIndex > failureIndex && notes[laterIndex].state == .sending {
            notes[laterIndex].state = .failed(message: "An earlier message did not send.")
            notes[laterIndex].sentAt = nil
        }
        queuedNotes[sessionID] = notes
        persistQueuedNotes()
    }

    private var uploadLimit: Int {
        latestBootstrap?.limits?.uploadMaxBytes ?? AttachmentNormalizer.maxFileBytes
    }

    static func uploadProgress(totalBytesSent: Int64, totalBytesExpectedToSend: Int64) -> Double {
        guard totalBytesExpectedToSend > 0 else { return 0 }
        return min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    private func startAttachmentUpload(_ item: AttachmentItem, sessionID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let uploaded = try await self.client.uploadFile(
                    sessionID: sessionID,
                    data: item.data,
                    filename: item.name,
                    mimeType: item.mimeType,
                    timeout: self.uploadTimeout,
                    progress: { [weak self] totalBytesSent, totalBytesExpectedToSend in
                        Task { @MainActor [weak self] in
                            self?.updateAttachmentProgress(
                                item.id,
                                sessionID: sessionID,
                                totalBytesSent: totalBytesSent,
                                totalBytesExpectedToSend: totalBytesExpectedToSend
                            )
                        }
                    }
                )
                self.attachmentProgressDates.removeValue(forKey: item.id)
                self.updateAttachment(item.id, sessionID: sessionID) { $0.state = .attached(uploaded) }
            } catch {
                self.attachmentProgressDates.removeValue(forKey: item.id)
                let mapped = self.actionError(for: error, fileName: item.name, limitBytes: self.uploadLimit)
                self.updateAttachment(item.id, sessionID: sessionID) { $0.state = .failed(mapped) }
            }
        }
    }

    private func updateAttachmentProgress(
        _ id: String,
        sessionID: String,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let progress = Self.uploadProgress(totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
        let now = clock.now
        let isFinal = progress >= 1
        if !isFinal, let lastUpdate = attachmentProgressDates[id], now.timeIntervalSince(lastUpdate) < 0.1 { return }
        attachmentProgressDates[id] = now
        updateAttachment(id, sessionID: sessionID) { $0.state = .uploading(progress: progress) }
    }

    private func isUploading(_ item: AttachmentItem) -> Bool {
        if case .uploading = item.state { return true }
        return false
    }

    private func updateAttachment(_ id: String, sessionID: String, update: (inout AttachmentItem) -> Void) {
        guard var items = attachments[sessionID], let index = items.firstIndex(where: { $0.id == id }) else { return }
        update(&items[index])
        attachments[sessionID] = items
        attachmentRevision += 1
    }

    public func interrupt(sessionID: String) async -> Result<Void, ActionError> {
        do {
            _ = try await client.escape(sessionID: sessionID)
            return .success(())
        } catch {
            return .failure(actionError(for: error))
        }
    }

    public func setApprovalMode(sessionID: String, mode: ApprovalMode) async -> Result<Void, ActionError> {
        guard mode == .auto || mode == .remote || mode == .terminal else { return .failure(.invalid("Approval mode is not supported.")) }
        let previousMode = sessions[sessionID]?.mode
        if var session = sessions[sessionID] {
            session.mode = mode
            sessions[sessionID] = session
            updateOpenStores(for: session)
        }
        do {
            let result = try await client.mode(sessionID: sessionID, mode: mode)
            guard var session = sessions[sessionID] else { return .failure(.invalid("Session is not live.")) }
            session.mode = approvalMode(result.mode ?? mode.rawValue)
            sessions[sessionID] = session
            updateOpenStores(for: session)
            scheduleCacheWrite()
            return .success(())
        } catch {
            if var session = sessions[sessionID] {
                session.mode = previousMode
                sessions[sessionID] = session
                updateOpenStores(for: session)
            }
            return .failure(actionError(for: error))
        }
    }

    public func downloadFile(sessionID: String, name: String) async throws -> (data: Data, mime: String?) {
        try await client.downloadFile(sessionID: sessionID, name: name)
    }

    public func commandModelOptions() async throws -> [ModelOption] {
        try await newSessionOptions().models
    }

    public func whoAmI() async throws -> WhoAmI {
        try await authenticate()
        return try await client.whoAmI()
    }

    public func pairedDevices() async throws -> [Device] {
        try await authenticate()
        return try await client.devices().devices ?? []
    }

    public func logout() async -> Result<Void, ActionError> {
        do {
            _ = try await client.logout()
            await clearLocalState()
            return .success(())
        } catch {
            return .failure(actionError(for: error))
        }
    }

    /// Forgets every session, approval, transcript and the bearer without calling the daemon, for unpairing.
    public func clearLocalState() async {
        suspend()
        await client.setBearerToken(nil)
        try? await cache.clear()
        draftCache.clear()
        queuedNoteCache.clear()
        drafts.removeAll()
        draftRevisions.removeAll()
        sessions.removeAll()
        previousSessionsForReplacement.removeAll()
        previousSessionsForReplacementAt = nil
        sleeping.removeAll()
        approvals.removeAll()
        deciding.removeAll()
        queuedNotes.removeAll()
        attachments.removeAll()
        attachmentProgressDates.removeAll()
        attachmentNotices.removeAll()
        debugAttachmentSessions.removeAll()
        openStores.removeAll()
        cachedTranscripts.removeAll()
        cacheChangedStoreKeys.removeAll()
        serverEntryCounts.removeAll()
        latestBootstrap = nil
        daemon = nil
        apiVersion = nil
        lastUpdated = nil
        connection = .offline(lastUpdated: nil, error: nil)
    }

    public func apply(_ event: LiveEvent) {
        switch event {
        case .connected:
            connection = .live
        case .state(let snapshot):
            #if CC_PERF
            PerfCounters.shared.hit(.sseState)
            #endif
            flushPendingEvents()
            applyMeasured(event) { [self] in applyState(snapshot) }
        case .stateDelta(let delta):
            #if CC_PERF
            PerfCounters.shared.hit(.sseStateDelta)
            #endif
            enqueue(CoalescedLiveEvent.stateDelta(delta))
        case .transcript(let transcript):
            #if CC_PERF
            PerfCounters.shared.hit(.sseTranscript)
            #endif
            flushPendingEvents(for: transcript.sessionId)
            applyMeasured(event) { [self] in applyTranscript(transcript) }
        case .usage(let usage):
            #if CC_PERF
            PerfCounters.shared.hit(.sseUsage)
            #endif
            enqueue(CoalescedLiveEvent.usage(usage))
        case .subagents(let subagents):
            #if CC_PERF
            PerfCounters.shared.hit(.sseSubagents)
            #endif
            enqueue(CoalescedLiveEvent.subagents(subagents))
        case .subagent(let subagent):
            #if CC_PERF
            PerfCounters.shared.hit(.sseSubagents)
            #endif
            enqueue(CoalescedLiveEvent.subagent(subagent))
        case .approval(let approval):
            flushPendingEvents(for: approval.sessionId)
            applyMeasured(event) { [self] in applyApproval(approval) }
        case .decision(let decision):
            flushPendingEvents(for: decision.sessionId)
            applyMeasured(event) { [self] in applyDecision(decision) }
        case .file:
            break
        case .registry:
            #if CC_PERF
            PerfCounters.shared.hit(.sseRegistry)
            #endif
            flushPendingEvents()
            refreshAfterRegistryEvent()
        case .sleeping(let event):
            sleeping = event.sleeping
            lastUpdated = clock.now
            scheduleCacheWrite()
        }
    }

    private func enqueue(_ event: CoalescedLiveEvent) {
        eventCoalescer.enqueue(event)
        guard eventCoalescingTask == nil else { return }
        eventCoalescingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            eventCoalescingTask = nil
            flushPendingEvents()
        }
    }

    private func flushPendingEvents(for sessionID: String? = nil) {
        let events = if let sessionID {
            eventCoalescer.drain(sessionID: sessionID)
        } else {
            eventCoalescer.drainAll()
        }
        for event in events {
            switch event {
            case .stateDelta(let delta): applyMeasured(.stateDelta(delta)) { [self] in applyStateDelta(delta) }
            case .usage(let usage): applyMeasured(.usage(usage)) { [self] in applyUsage(usage) }
            case .subagents(let subagents): applyMeasured(.subagents(subagents)) { [self] in applySubagents(subagents) }
            case .subagent(let subagent): applyMeasured(.subagent(subagent)) { [self] in applySubagent(subagent) }
            }
        }
        if eventCoalescer.isEmpty {
            eventCoalescingTask?.cancel()
            eventCoalescingTask = nil
        }
    }

    private func applyMeasured(_ event: LiveEvent, operation: () -> Void) {
        #if CC_PERF
        let started = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        PerfCounters.shared.recordMilliseconds(.mainActorBusyMilliseconds, value: elapsed)
        switch event {
        case .stateDelta: PerfCounters.shared.recordMilliseconds(.stateDeltaApplyMilliseconds, value: elapsed)
        case .subagents, .subagent: PerfCounters.shared.recordMilliseconds(.subagentsApplyMilliseconds, value: elapsed)
        case .transcript: PerfCounters.shared.recordMilliseconds(.transcriptApplyMilliseconds, value: elapsed)
        default: break
        }
        #else
        operation()
        #endif
    }

    private func decide(_ approval: Approval, behavior: DecisionBehavior) async -> Result<Void, ActionError> {
        guard let sessionID = approval.sessionId, let requestID = approval.requestId, !requestID.isEmpty else { return .failure(.invalid("Approval is missing its request id.")) }
        let key = "\(sessionID):\(requestID)"
        deciding.insert(key)
        removePendingApproval(approval)
        defer { deciding.remove(key) }
        do {
            _ = try await client.decision(sessionID: sessionID, requestID: requestID, behavior: behavior)
            _ = await refreshStateAndOpenTranscripts()
            return .success(())
        } catch {
            if isStaleDecision(error) {
                _ = await refreshStateAndOpenTranscripts()
            } else {
                restorePendingApproval(approval)
            }
            return .failure(actionError(for: error))
        }
    }

    private func removePendingApproval(_ approval: Approval) {
        guard let sessionID = approval.sessionId, var session = sessions[sessionID] else { return }
        session.pending = (session.pending ?? []).filter { $0.requestId != approval.requestId }
        sessions[sessionID] = session
        approvals = sessions.values.flatMap { $0.pending ?? [] }
        updateOpenStores(for: session)
    }

    private func restorePendingApproval(_ approval: Approval) {
        guard let sessionID = approval.sessionId, var session = sessions[sessionID] else { return }
        var pending = session.pending ?? []
        guard !pending.contains(where: { $0.requestId == approval.requestId }) else { return }
        pending.append(approval)
        pending.sort { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) }
        session.pending = pending
        sessions[sessionID] = session
        approvals = sessions.values.flatMap { $0.pending ?? [] }
        updateOpenStores(for: session)
    }

    private func refreshStateAndOpenTranscripts() async -> Bool {
        guard let snapshot = try? await client.state() else { return false }
        applyState(snapshot)
        for store in openStores.values { try? await store.refetchTail() }
        return true
    }

    private func isStaleDecision(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .stale, .staleResponse: return true
        default: return false
        }
    }

    public func actionError(for error: Error, fileName: String? = nil, limitBytes: Int? = nil) -> ActionError {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized: return .unauthorized
            case .stale: return .alreadyAnswered
            case .staleResponse(let status, let message, let code):
                if code == "terminal_no_pane" { return .waitingInTerminal }
                if code == "already_answered" || status == 410 { return .alreadyAnswered }
                if code == "no_pane" { return .noPane }
                if status == 409 && message.localizedCaseInsensitiveContains("terminal") { return .waitingInTerminal }
                return .server(status: status, message: message)
            case .transport(let urlError):
                return urlError.code == .timedOut ? .timeout : .network(urlError.localizedDescription)
            case .http(let status, let message, let code):
                if code == "no_command_route" { return .commandsUnavailable(message) }
                if code == "terminal_no_pane" { return .waitingInTerminal }
                if code == "no_pane" { return .noPane }
                if code == "already_answered" { return .alreadyAnswered }
                if code == "too_large" || status == 413 { return .tooLarge(fileName: fileName ?? "File", limitBytes: limitBytes ?? 0) }
                if message.localizedCaseInsensitiveContains("no tmux pane") || (status == 409 && message.localizedCaseInsensitiveContains("pane")) { return .noPane }
                return .server(status: status, message: message)
            case .rateLimited: return .server(status: 429, message: "Too many requests")
            case .decoding(let message): return .unreadable(message)
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network(urlError.localizedDescription)
        }
        return .server(status: 0, message: error.localizedDescription)
    }

    private func approvalMode(_ rawValue: String) -> ApprovalMode {
        switch rawValue {
        case "auto": .auto
        case "remote": .remote
        case "terminal": .terminal
        default: .unknown(rawValue)
        }
    }

    private func connectInitially() async {
        await loadCache()
        guard started else { return }
        do {
            try await authenticate()
            try await bootstrapAndReconcile(resetTranscripts: false)
            guard started else { return }
            openEventStream()
        } catch {
            handleConnectionError(error)
        }
    }

    private func authenticate() async throws {
        let token = try await bearerProvider()
        await client.setBearerToken(token)
    }

    private func openEventStream() {
        let stream = EventStream(
            client: client,
            clock: clock,
            beforeReconnect: { [weak self] attempt in
                guard let self else { return false }
                return await self.prepareReconnect(attempt: attempt)
            }
        )
        eventStream = stream
        eventTask = Task { [weak self, stream] in
            for await event in stream.events {
                guard let self else { return }
                self.apply(event)
            }
        }
        statusTask = Task { [weak self, stream] in
            for await status in stream.statuses {
                guard let self else { return }
                self.apply(status)
            }
        }
        unknownTask = Task { [weak self, stream] in
            for await _ in stream.unknownEvents {
                guard let self else { return }
                self.unknownEventCount += 1
            }
        }
        Task { await stream.start() }
    }

    private func apply(_ status: ConnectionStatus) {
        switch status {
        case .connecting:
            if started { connection = .connecting }
        case .live:
            connection = .live
        case .reconnecting(let attempt):
            connection = .reconnecting(attempt: attempt, since: reconnectSince ?? clock.now)
        case .offline:
            if started { connection = .offline(lastUpdated: lastUpdated, error: nil) }
        }
    }

    private func prepareReconnect(attempt: Int) async -> Bool {
        guard started else { return false }
        reconnectSince = reconnectSince ?? clock.now
        connection = .reconnecting(attempt: attempt, since: reconnectSince ?? clock.now)
        do {
            try await authenticate()
            try await bootstrapAndReconcile(resetTranscripts: false)
            reconnectSince = nil
            return started
        } catch let error as APIError {
            if error == .unauthorized {
                guard let handler = authenticationFailureHandler else {
                    connection = .unauthorized
                    started = false
                    return false
                }
                await handler()
                do {
                    try await authenticate()
                    try await bootstrapAndReconcile(resetTranscripts: false)
                    reconnectSince = nil
                    return started
                } catch {
                    if let retryError = error as? APIError, case .decoding = retryError {
                        connection = connectionState(for: retryError)
                    } else {
                        connection = .unauthorized
                    }
                    started = false
                    return false
                }
            }
            connection = connectionState(for: error)
            return started
        } catch {
            connection = connectionState(for: error)
            return started
        }
    }

    private func bootstrapAndReconcile(resetTranscripts: Bool, refetchOpenTranscripts: Bool = true) async throws {
        #if CC_PERF
        PerfCounters.shared.hit(.bootstrapAndReconcile)
        #endif
        let bootstrap = try await client.bootstrap()
        let startedAtChanged = resetTranscripts || hasDaemonRestarted(bootstrap.daemon)
        if startedAtChanged { resetOpenTranscripts() }
        latestBootstrap = bootstrap
        if let controller = bootstrap.controller { controllerInfo = controller }
        daemon = bootstrap.daemon
        apiVersion = bootstrap.apiVersion
        if let state = bootstrap.state { applyState(state) }
        lastUpdated = clock.now
        if refetchOpenTranscripts {
            for store in openStores.values {
                if startedAtChanged { try await store.refetchTail(reset: true) }
                else { try await store.refetchTail() }
            }
        }
        scheduleCacheWrite()
    }

    private func hasDaemonRestarted(_ newDaemon: DaemonInfo?) -> Bool {
        guard let old = daemon?.startedAt, let new = newDaemon?.startedAt else { return false }
        return old != new
    }

    private func applyState(_ snapshot: StateSnapshot) {
        let liveSessions = (snapshot.sessions ?? []).compactMap { session -> (String, Session)? in
            guard let id = session.id else { return nil }
            var session = session
            if let previous = sessions[id] {
                if isPlaceholderUsage(session.usage), let usage = previous.usage {
                    session.usage = usage
                }
                if session.background == nil {
                    session.background = previous.background
                }
            }
            return (id, session)
        }
        let nextSessions = Dictionary(uniqueKeysWithValues: liveSessions)
        if Set(sessions.keys) != Set(nextSessions.keys) {
            previousSessionsForReplacement = sessions
            previousSessionsForReplacementAt = clock.now
        }
        sessions = nextSessions
        sleeping = snapshot.sleeping ?? sleeping
        serverEntryCounts = snapshot.entries ?? [:]
        approvals = sessions.values.flatMap { $0.pending ?? [] }
        for store in openStores.values {
            if let session = sessions[store.sessionID] {
                store.updateSession(session)
            } else {
                var closed = store.session
                closed.live = false
                store.updateSession(closed)
            }
        }
        pruneCachedTranscripts()
        lastUpdated = clock.now
        scheduleCacheWrite()
        refetchStoresForCounts(snapshot.entries ?? [:])
    }

    private func applyStateDelta(_ delta: StateDelta) {
        guard let id = delta.sessionId, var session = sessions[id] else { return }
        if delta.rawObject["state"] != nil { session.state = delta.state }
        if delta.rawObject["action"] != nil { session.action = delta.action }
        if delta.rawObject["startedAt"] != nil { session.startedAt = delta.startedAt }
        if delta.rawObject["idleSince"] != nil { session.idleSince = delta.idleSince }
        if delta.rawObject["lastTool"] != nil { session.lastTool = delta.lastTool }
        if delta.rawObject["lastToolInput"] != nil { session.lastToolInput = delta.lastToolInput }
        if delta.rawObject["toolRunning"] != nil { session.toolRunning = delta.toolRunning }
        if delta.rawObject["lastText"] != nil { session.lastText = delta.lastText }
        if delta.rawObject["usage"] != nil { session.usage = delta.usage }
        if delta.rawObject["subagents"] != nil { session.subagents = delta.subagents }
        if delta.rawObject["shells"] != nil { session.shells = delta.shells }
        if delta.rawObject["pending"] != nil { session.pending = delta.pending }
        sessions[id] = session
        if delta.rawObject["entries"] != nil, let counts = delta.entries {
            serverEntryCounts.merge(counts) { _, new in new }
        }
        updateOpenStores(for: session)
        approvals = sessions.values.flatMap { $0.pending ?? [] }
        lastUpdated = clock.now
        scheduleCacheWrite()
        refetchStoresForCounts(delta.entries ?? [:])
    }

    private func applyTranscript(_ event: TranscriptEvent) {
        guard let sessionID = event.sessionId, let entry = event.entry else { return }
        guard let store = openStores[storeKey(sessionID: sessionID, agentID: nil)] else { return }
        let countBefore = store.totalEntries
        let change = store.merge(
            [entry],
            replace: event.replace == true,
            entryCount: event.entryCount,
            appendNewEntries: true
        )
        let expectedCount = countBefore + (change.inserted.isEmpty ? 0 : 1)
        if let entryCount = event.entryCount {
            serverEntryCounts[sessionID] = entryCount
            if entryCount > expectedCount { refetchStoreGap(store, missing: entryCount - expectedCount) }
        }
        scheduleCacheWrite()
    }

    private func reconcileQueuedNotes(for sessionID: String, changedEntries: [TranscriptEntry]) {
        guard var pending = queuedNotes[sessionID] else { return }
        for entry in changedEntries {
            pending = reconcileQueuedNote(pending, promptEntry: entry)
            if pending.isEmpty { break }
        }
        if pending.isEmpty { queuedNotes.removeValue(forKey: sessionID) }
        else { queuedNotes[sessionID] = pending }
        persistQueuedNotes()
    }

    private func applyUsage(_ event: UsageEvent) {
        guard let sessionID = event.sessionId, var session = sessions[sessionID], let usage = event.usage else { return }
        session.usage = usage
        sessions[sessionID] = session
        updateOpenStores(for: session)
        #if DEBUG
        TranscriptPerformance.shared.markUsageUpdate()
        #endif
        lastUpdated = clock.now
        scheduleCacheWrite()
    }

    private func applySubagents(_ event: SubagentsEvent) {
        guard let sessionID = event.sessionId, var session = sessions[sessionID] else { return }
        guard session.subagents != event.subagents else { return }
        session.subagents = event.subagents
        sessions[sessionID] = session
        updateOpenStores(for: session)
        lastUpdated = clock.now
        scheduleCacheWrite()
    }

    private func applySubagent(_ event: SubagentEvent) {
        guard let sessionID = event.sessionId, var session = sessions[sessionID], let incoming = event.subagents else { return }
        var merged = session.subagents ?? []
        for value in incoming {
            if let identity = subagentIdentity(value), let index = merged.firstIndex(where: { subagentIdentity($0) == identity }) {
                merged[index] = value
            } else {
                merged.append(value)
            }
        }
        let positions: [String: Int] = Dictionary(merged.enumerated().compactMap { index, value in
            guard let identity = subagentIdentity(value) else { return nil }
            return (identity, index)
        }, uniquingKeysWith: { first, _ in first })
        merged.sort { left, right in
            let leftDate = left.startedAt ?? .distantPast
            let rightDate = right.startedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            let leftPosition = positions[subagentIdentity(left) ?? ""] ?? 0
            let rightPosition = positions[subagentIdentity(right) ?? ""] ?? 0
            return leftPosition < rightPosition
        }
        guard session.subagents != merged else { return }
        session.subagents = merged
        sessions[sessionID] = session
        updateOpenStores(for: session)
        lastUpdated = clock.now
        scheduleCacheWrite()
    }

    private func applyApproval(_ event: ApprovalEvent) {
        guard let sessionID = event.sessionId, let requestID = event.requestId else { return }
        var pending = sessions[sessionID]?.pending ?? []
        let approval = Approval(
            requestId: requestID,
            sessionId: sessionID,
            toolName: event.toolName,
            toolInput: event.toolInput,
            toolUseId: event.toolUseId,
            permissionMode: event.permissionMode,
            agentType: event.agentType,
            receivedAt: event.receivedAt,
            holdLimitMs: event.holdLimitMs,
            mode: event.mode,
            status: event.status,
            timedOutAt: event.timedOutAt,
            permissionSuggestions: event.permissionSuggestions
        )
        pending.removeAll { $0.requestId == requestID }
        pending.append(approval)
        updatePending(pending, for: sessionID)
    }

    private func applyDecision(_ event: DecisionEvent) {
        guard let sessionID = event.sessionId, let requestID = event.requestId else { return }
        let pending = (sessions[sessionID]?.pending ?? []).filter { $0.requestId != requestID }
        updatePending(pending, for: sessionID)
    }

    private func updatePending(_ pending: [Approval], for sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.pending = pending
        if !pending.isEmpty { session.state = .needsYou }
        sessions[sessionID] = session
        approvals = sessions.values.flatMap { $0.pending ?? [] }
        updateOpenStores(for: session)
        lastUpdated = clock.now
        scheduleCacheWrite()
    }

    private func updateOpenStores(for session: Session) {
        guard let id = session.id else { return }
        for store in openStores.values where store.sessionID == id {
            store.updateSession(session)
        }
    }

    private func refreshAfterRegistryEvent() {
        guard started else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.bootstrapAndReconcile(resetTranscripts: false, refetchOpenTranscripts: false) }
            catch { self.handleConnectionError(error) }
        }
    }

    private func refetchStoresForCounts(_ counts: [String: Int]) {
        for store in openStores.values {
            guard let count = counts[store.sessionID], count > store.totalEntries else { continue }
            refetchStoreGap(store, missing: count - store.totalEntries)
        }
    }

    static func gapFetchLimit(missing: Int) -> Int {
        min(400, max(1, missing + 20))
    }

    public static func replacementSessionID(
        missingSessionID: String,
        previousSessions: [String: Session],
        currentSessions: [String: Session],
        missingAt: Date,
        now: Date,
        window: TimeInterval = 10
    ) -> String? {
        guard now.timeIntervalSince(missingAt) >= 0,
              now.timeIntervalSince(missingAt) <= window,
              let missing = previousSessions[missingSessionID],
              let pid = missing.pid else { return nil }
        return currentSessions.values.first {
            $0.id != missingSessionID && $0.pid == pid && $0.live == true
        }?.id
    }

    private func refetchStoreGap(_ store: SessionStore, missing: Int) {
        let limit = Self.gapFetchLimit(missing: missing)
        Task { try? await store.refetchGap(limit: limit) }
    }

    private func openStore(sessionID: String, agentID: String?) -> SessionStore? {
        let key = storeKey(sessionID: sessionID, agentID: agentID)
        if let store = openStores[key] { return store }
        guard let session = sessions[sessionID], session.live == true else { return nil }
        let entries = cachedTranscripts[key] ?? []
        let store = SessionStore(
            session: session,
            client: client,
            agentID: agentID,
            entries: entries,
            onTranscriptChange: { [weak self] changedEntries in
                guard let self else { return }
                self.transcriptDidChange(for: key)
                guard agentID == nil, !changedEntries.isEmpty else { return }
                self.reconcileQueuedNotes(for: sessionID, changedEntries: changedEntries)
            },
            initialTranscriptTail: initialTranscriptTail
        )
        openStores[key] = store
        if agentID == nil { reconcileQueuedNotes(for: sessionID, changedEntries: entries) }
        Task {
            do { _ = try await store.loadInitial() }
            catch {
                #if DEBUG
                appLogger.debug("initial transcript load failed session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                #endif
            }
        }
        return store
    }

    private func resetOpenTranscripts() {
        for store in openStores.values { store.resetTranscript() }
    }

    private func loadCache() async {
        guard let state = try? await cache.load() else { return }
        applyState(state.bootstrap.state ?? StateSnapshot())
        daemon = state.bootstrap.daemon
        apiVersion = state.bootstrap.apiVersion
        latestBootstrap = state.bootstrap
        lastUpdated = state.updatedAt
        cachedTranscripts = state.transcripts
        pruneCachedTranscripts()
        if state.loadedLegacyFormat { cacheChangedStoreKeys.formUnion(cachedTranscripts.keys) }
        connection = .offline(lastUpdated: state.updatedAt, error: nil)
    }

    private func scheduleCacheWrite() {
        #if CC_PERF
        PerfCounters.shared.hit(.scheduleCacheWrite)
        #endif
        guard latestBootstrap != nil else { return }
        cacheWritePending = true
        guard cacheWriteTask == nil else { return }
        cacheWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.cacheWriteDebounce)
            } catch {
                return
            }
            guard let self else { return }
            cacheWriteTask = nil
            writeCacheSnapshot()
        }
    }

    private func flushCacheImmediately() {
        cacheWriteTask?.cancel()
        cacheWriteTask = nil
        writeCacheSnapshot()
    }

    private func writeCacheSnapshot() {
        guard cacheWritePending, let state = cacheStateSnapshot() else { return }
        let changedKeys = cacheChangedStoreKeys
        let changedTranscripts = changedKeys.reduce(into: [String: [TranscriptEntry]]()) { result, key in
            if let store = openStores[key] {
                let entries = Array(store.entries.suffix(400))
                cachedTranscripts[key] = entries
                result[key] = entries
            } else if let entries = cachedTranscripts[key] {
                result[key] = entries
            }
        }
        cacheWritePending = false
        cacheChangedStoreKeys.subtract(changedKeys)
        Task {
            await cache.saveNow(
                state,
                changedTranscripts: changedTranscripts,
                retainedTranscriptKeys: validCacheKeys
            )
        }
    }

    private func cacheStateSnapshot() -> DiskCacheState? {
        guard let latestBootstrap else { return nil }
        return DiskCacheState(
            bootstrap: Bootstrap(
                apiVersion: latestBootstrap.apiVersion,
                daemon: daemon,
                capabilities: latestBootstrap.capabilities,
                limits: latestBootstrap.limits,
                state: StateSnapshot(sessions: Array(sessions.values), entries: serverEntryCounts, device: latestBootstrap.state?.device, sleeping: sleeping)
            ),
            updatedAt: lastUpdated ?? clock.now
        )
    }

    private func closeStore(forKey key: String) {
        guard let store = openStores.removeValue(forKey: key) else { return }
        cachedTranscripts[key] = Array(store.entries.suffix(400))
        cacheChangedStoreKeys.insert(key)
        cacheWritePending = true
        writeCacheSnapshot()
    }

    private func transcriptDidChange(for key: String) {
        guard openStores[key] != nil else { return }
        cacheChangedStoreKeys.insert(key)
        scheduleCacheWrite()
    }

    private var validCacheKeys: Set<String> {
        Set(cachedTranscripts.keys.filter { key in
            guard let sessionID = key.split(separator: "|", maxSplits: 1).first else { return false }
            return sessions[String(sessionID)] != nil
        })
    }

    private func pruneCachedTranscripts() {
        let validKeys = validCacheKeys
        cachedTranscripts = cachedTranscripts.filter { validKeys.contains($0.key) }
        cacheChangedStoreKeys = cacheChangedStoreKeys.filter { validKeys.contains($0) }
    }

    private func connectionState(for error: Error) -> ConnectionState {
        let message = error.localizedDescription
        if let apiError = error as? APIError, case .decoding = apiError {
            return .offlineUnreadable(lastUpdated: lastUpdated, error: message)
        }
        return .offline(lastUpdated: lastUpdated, error: message)
    }

    private func handleConnectionError(_ error: Error) {
        if let apiError = error as? APIError, apiError == .unauthorized {
            connection = .unauthorized
            started = false
            return
        }
        connection = connectionState(for: error)
        started = false
    }

    private func storeKey(sessionID: String, agentID: String?) -> String {
        agentID.map { "\(sessionID)|\($0)" } ?? sessionID
    }

    private func draftKey(sessionID: String, agentID: String?) -> String {
        storeKey(sessionID: sessionID, agentID: agentID)
    }

    private func activityDate(_ session: Session) -> Date {
        session.startedAt ?? session.idleSince ?? .distantPast
    }

    private func isPlaceholderUsage(_ usage: Usage?) -> Bool {
        guard let usage else { return true }
        let model = usage.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let values = [
            usage.contextTokens,
            usage.contextWindow,
            usage.inputTokens,
            usage.totalInputTokens,
            usage.outputTokens,
            usage.cacheReadTokens,
            usage.cacheWriteTokens,
            usage.messages,
        ]
        return model.isEmpty && values.allSatisfy { ($0 ?? 0) <= 0 } && (usage.contextPercent ?? 0) <= 0 && (usage.cacheHitRate ?? 0) <= 0
    }
}
