import CCKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SessionDestination: Hashable {
    let sessionID: String
    let agentID: String
}

private struct SessionLoadKey: Hashable {
    let sessionID: String
    let hasSession: Bool
    let isLive: Bool
}

struct SubagentResultSelection: Identifiable {
    let entry: SubagentResultEntry
    let subagent: Subagent?

    var id: String {
        entry.id ?? entry.toolUseId ?? entry.agentId ?? "subagent-result"
    }
}

struct SessionScreen: View {

    let sessionID: String
    let store: AppStore
    @Bindable var model: AppModel
    let approvalsElsewhereCount: Int
    let isWaking: Bool
    let wakeError: String?
    let onRetryWake: () -> Void
    let onShowApprovalsElsewhere: () -> Void
    /// The sidebar has just taken the room the inspector would need, so an open inspector closes.
    let sidebarCrowdsInspector: Bool
    let onRegularInspectorWillOpen: () -> Void
    let onRegularInspectorChange: (Bool) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        sessionID: String,
        store: AppStore,
        model: AppModel,
        approvalsElsewhereCount: Int = 0,
        isWaking: Bool = false,
        wakeError: String? = nil,
        onRetryWake: @escaping () -> Void = {},
        onShowApprovalsElsewhere: @escaping () -> Void = {},
        sidebarCrowdsInspector: Bool = false,
        onRegularInspectorWillOpen: @escaping () -> Void = {},
        onRegularInspectorChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.store = store
        self.model = model
        self.approvalsElsewhereCount = approvalsElsewhereCount
        self.isWaking = isWaking
        self.wakeError = wakeError
        self.onRetryWake = onRetryWake
        self.onShowApprovalsElsewhere = onShowApprovalsElsewhere
        self.sidebarCrowdsInspector = sidebarCrowdsInspector
        self.onRegularInspectorWillOpen = onRegularInspectorWillOpen
        self.onRegularInspectorChange = onRegularInspectorChange
    }
    @State private var selectedTool: ToolEntry?
    @State private var selectedCompaction: CompactionEntry?
    @State private var selectedSubagentResult: SubagentResultSelection?
    @State private var inspectorPresented = false
    @State private var activityPresented = false
    @State private var filePreviewURL: URL?
    @State private var destination: SessionDestination?
    @State private var pendingInspectorDestination: SessionDestination?
    @State private var pendingSubagentDestination: SessionDestination?
    @State private var pendingActivityDestination: SessionDestination?
    @State private var allowFeedbackCount = 0
    @State private var denyFeedbackCount = 0
    @State private var answeredFeedbackCount = 0
    @State private var questionState = QuestionCardState()
    @State private var knownApprovalIDs: Set<String> = []
    @State private var modelSheetPresented = false
    @State private var commandOutput: CommandOutput?
    @State private var commandToast: String?
    @State private var commandToastTask: Task<Void, Never>?
    @State private var lifecycleScreenInstanceID = UUID()
    @State private var sendRevealCoordinator = SendRevealCoordinator()
    @State private var sendAcceptedRevision = 0

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var composerCapabilities: ComposerCapabilities {
        ComposerCapabilities(controllerCapabilities: store.controllerInfo.capabilities)
    }

    private var approvalsElsewhereText: String {
        approvalsElsewhereCount == 1 ? "1 needs you" : "\(approvalsElsewhereCount) need you"
    }

    private var approvalsElsewhereAccessibilityLabel: String {
        approvalsElsewhereCount == 1 ? "1 session needs you" : "\(approvalsElsewhereCount) sessions need you"
    }

    private var filePreviewPresented: Binding<Bool> {
        Binding(
            get: { filePreviewURL != nil },
            set: { presented in if !presented { filePreviewURL = nil } }
        )
    }

    /// The image at a local file URL, or nil when it isn't one, so it opens in Quick Look instead.
    private func previewImage(at url: URL) -> UIImage? {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        screen()
            .sheet(isPresented: filePreviewPresented) {
                if let filePreviewURL {
                    Group {
                        if let image = previewImage(at: filePreviewURL) {
                            ImagePreviewSheet(url: filePreviewURL, image: image, close: { self.filePreviewURL = nil })
                        } else {
                            FilePreviewSheet(url: filePreviewURL, close: { self.filePreviewURL = nil })
                        }
                    }
                        .ignoresSafeArea()
                        .presentationDragIndicator(.visible)
                }
            }
        .sensoryFeedback(.success, trigger: allowFeedbackCount)
        .sensoryFeedback(.warning, trigger: denyFeedbackCount)
        .sensoryFeedback(.impact(weight: .light), trigger: answeredFeedbackCount)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: pendingApprovalCount) { oldCount, newCount in
            newCount > oldCount
        }
        .onChange(of: approvalRequestIDs) { _, requestIDs in
            announceNewApprovals(requestIDs)
        }
        .onChange(of: sessionID) { _, _ in
            knownApprovalIDs = []
        }
        .sheet(isPresented: compactInspectorBinding, onDismiss: presentPendingInspectorDestination) {
            inspectorContent()
        }
        .inspector(isPresented: regularInspectorBinding) {
            inspectorContent()
        }
        .onChange(of: regularInspectorBinding.wrappedValue, initial: true) { _, isOpen in
            onRegularInspectorChange(isOpen)
        }
        .onChange(of: sidebarCrowdsInspector) { _, isCrowded in
            if isCrowded, !isCompact { inspectorPresented = false }
        }
        .overlay(alignment: .top) {
            if let commandToast {
                CommandToastView(message: commandToast)
                    .padding(.top, isCompact ? 8 : RegularHeaderMetrics.rowHeight + 8)
            }
        }
        .onDisappear {
            commandToastTask?.cancel()
            onRegularInspectorChange(false)
            recordLifecycleEvent(name: "screen-disappear", sessionID: sessionID)
        }
        .background {
            // TODO: move to navigationDestination once the split-view detail stack keeps the toolbar (see tasks/native-app.md Open)
            NavigationLink(isActive: destinationBinding) {
                if let destination {
                    SubagentScreen(
                        sessionID: destination.sessionID,
                        agentID: destination.agentID,
                        store: store,
                        model: model
                    )
                }
            } label: {
                EmptyView()
            }
            .hidden()
        }
        .task(id: sessionLoadKey) {
            let key = sessionLoadKey
            guard key.hasSession,
                  let sessionStore = store.openSession(key.sessionID) else { return }
            guard !sessionStore.isLoaded else {
                #if DEBUG || CC_PERF
                store.addDebugAttachments(model.debugAttachmentPaths, to: key.sessionID)
                #endif
                return
            }
            do {
                try await sessionStore.loadInitial()
                #if DEBUG || CC_PERF
                store.addDebugAttachments(model.debugAttachmentPaths, to: key.sessionID)
                #endif
            } catch {
                guard !isTranscriptCancellation(error) else { return }
                model.actionError = store.actionError(for: error)
            }
        }
        .onAppear {
            recordLifecycleEvent(name: "screen-appear", sessionID: sessionID)
            #if DEBUG || CC_PERF
            TranscriptPerformance.shared.beginScreenAppearance(sessionID: sessionID)
            #endif
        }
        .onDisappear {
            guard destination == nil else { return }
            store.closeSession(sessionID)
        }
    }

    @ViewBuilder
    private func screen() -> some View {
        let _ = store.attachmentRevision
        let _ = store.draftRevision(for: sessionID)
        let _ = store.pendingTurnStarts
        let _ = store.queuedNotes
        let _ = store.reconciledNoteAliases
        let pendingTurnStart = store.pendingTurnStart(for: sessionID)
        if let sessionStore = store.openSession(sessionID) {
            let currentSession = store.sessions[sessionID] ?? sessionStore.session
            contentNavigation(
                name: sessionStore.session.name ?? "Session",
                session: sessionStore.session
            ) {
                TranscriptReadinessGate(
                    readiness: sessionStore.readiness,
                    onSyncingAppear: {
                        recordLifecycleEvent(
                            name: "screen-branch",
                            sessionID: sessionID,
                            detail: TranscriptScreenBranch.loadingUnloaded.rawValue,
                            input: .screenBranch(
                                screenID: lifecycleScreenInstanceID.uuidString,
                                sessionID: sessionID,
                                branch: .loadingUnloaded
                            )
                        )
                    }
                ) {
                    SessionTranscriptView(
                        sessionID: sessionID,
                        turns: sessionStore.turns,
                        rows: sessionStore.rows,
                        bottomStackConfiguration: bottomStackConfiguration(
                            for: sessionStore.session,
                            liveSession: store.sessions[sessionID],
                            transcriptEntries: sessionStore.entries
                        ),
                        queuedNotes: store.queuedNotes(for: sessionID),
                        noteAliases: store.reconciledNoteAliases(for: sessionID),
                        sendRevealCoordinator: sendRevealCoordinator,
                        sendAcceptedRevision: sendAcceptedRevision,
                        activityFooter: activityFooter(
                            for: currentSession,
                            pendingTurnStart: pendingTurnStart
                        ),
                        liveSession: sessionStore.session,
                        sessionState: sessionStore.session.state,
                        onRetryNote: { noteID in
                            _ = store.retryNote(id: noteID, sessionID: sessionID)
                        },
                        onEditNote: { noteID in
                            _ = store.editNote(id: noteID, sessionID: sessionID)
                        },
                        onDeleteNote: { noteID in
                            _ = store.deleteNote(id: noteID, sessionID: sessionID)
                        },
                        onCopyNote: { noteID in
                            if let note = store.queuedNotes(for: sessionID).first(where: { $0.id == noteID }) {
                                UIPasteboard.general.string = note.text
                            }
                        },
                        onSendAgain: { noteID in
                            _ = store.sendAgain(id: noteID, sessionID: sessionID)
                        },
                        subagents: sessionStore.session.subagents ?? [],
                        hasMoreEarlier: sessionStore.hasMoreEarlier,
                        loadEarlier: { try await sessionStore.loadEarlier() },
                        onTool: { selectedTool = $0 },
                        onSubagent: openSubagent,
                        onSubagentResult: { entry, subagent in
                            selectedSubagentResult = SubagentResultSelection(entry: entry, subagent: subagent)
                        },
                        onCompaction: { selectedCompaction = $0 },
                        downloadFile: transcriptDownload
                    )
                    .environment(\.openInspector, { openInspector() })
                    .environment(\.openFilePreview, { filePreviewURL = $0 })
                    .onAppear {
                        recordLifecycleEvent(
                            name: "screen-branch",
                            sessionID: sessionID,
                            detail: TranscriptScreenBranch.transcript.rawValue,
                            input: .screenBranch(
                                screenID: lifecycleScreenInstanceID.uuidString,
                                sessionID: sessionID,
                                branch: .transcript
                            )
                        )
                    }
                }
                .id(sessionID)
            }
            .sheet(isPresented: toolSheetPresented) {
                if let selectedTool {
                    if let questionModel = questionSheetModel(for: selectedTool) {
                        QuestionAnswerSheet(model: questionModel)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    } else {
                        ToolDetailSheet(tool: selectedTool)
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                }
            }
            .sheet(isPresented: compactionSheetPresented) {
                if let selectedCompaction {
                    CompactionSummarySheet(entry: selectedCompaction)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $selectedSubagentResult, onDismiss: presentPendingSubagentDestination) { selection in
                SubagentResultSheet(
                    entry: selection.entry,
                    subagent: selection.subagent,
                    onViewTranscript: {
                        openSubagentTranscript(selection)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $activityPresented, onDismiss: presentPendingActivityDestination) {
                if let session = store.openSession(sessionID)?.session {
                    ActivitySheet(session: session, onSubagent: openSubagentFromActivity)
                }
            }
            .sheet(isPresented: $modelSheetPresented) {
                if let session = store.openSession(sessionID)?.session {
                    CommandModelSheet(
                        session: session,
                        loadModels: { try await store.commandModelOptions() },
                        onSelect: { id in
                            await store.sendResult(text: "/model \(id)", attachments: [], to: sessionID)
                        }
                    )
                }
            }
            .sheet(item: $commandOutput) { output in
                CommandOutputSheet(command: output.command, output: output.output) {
                    commandOutput = nil
                }
            }
        } else {
            TranscriptSyncingView()
                .onAppear {
                    recordLifecycleEvent(
                        name: "screen-branch",
                        sessionID: sessionID,
                        detail: TranscriptScreenBranch.loadingNoStore.rawValue,
                        input: .screenBranch(
                            screenID: lifecycleScreenInstanceID.uuidString,
                            sessionID: sessionID,
                            branch: .loadingNoStore
                        )
                    )
                }
                .navigationTitle("Session")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func activityFooter(
        for session: Session,
        pendingTurnStart: Date?
    ) -> CCKit.ActivityFooter? {
        guard session.state == .working || session.state == .needsYou || pendingTurnStart != nil else { return nil }
        let turnStart = pendingTurnStart ?? session.startedAt
        return activityFooterText(
            session,
            verb: spinnerVerb(sessionID: sessionID, turnStart: turnStart),
            startedAt: pendingTurnStart,
            pendingTurnStart: pendingTurnStart
        )
    }

    private func bottomStackConfiguration(
        for session: Session,
        liveSession: Session? = nil,
        transcriptEntries: [TranscriptEntry] = []
    ) -> BottomStackConfiguration {
        let commands = defaultSlashCommands.map { SlashCommand(command: $0.command, description: $0.description) }
        let current = liveSession ?? session
        let transcriptModel = transcriptEntries.reversed().compactMap { entry -> String? in
            guard case .assistant(let assistant) = entry else { return nil }
            return assistant.model
        }.first
        let modelName = current.usage?.model ?? transcriptModel
        return BottomStackConfiguration(
            sessionID: sessionID,
            sendRevealCoordinator: sendRevealCoordinator,
            composer: ComposerConfiguration(
                draft: ComposerDraft(
                    initialText: { store.draft(for: sessionID) },
                    revision: store.draftRevision(for: sessionID),
                    onChange: { text in store.setDraft(text, for: sessionID) }
                ),
                modelName: composerModelName(modelName),
                placeholder: current.state == .working ? "Queue for after this turn…" : "Message",
                isWorking: current.state == .working,
                canSend: current.live == true,
                canInterrupt: store.supports(.interrupt)
                    && (current.tmuxPane?.isEmpty == false || current.commandRoute == "mod"),
                canAttach: composerCapabilities.canAttach,
                canRunCommands: composerCapabilities.canRunCommands
            ),
            activitySession: current,
            waking: isWaking,
            wakeError: wakeError,
            onRetryWake: onRetryWake,
            onActivity: { activityPresented = true },
            slashCommands: slashCommands(commands, for: current),
            attachments: (store.attachments[sessionID] ?? []).map(ComposerAttachment.init(item:)),
            attachmentNotice: store.attachmentNotices[sessionID],
            approvals: pendingApprovals,
            deciding: store.deciding,
            onSend: { [model] text, now in
                recordLifecycleEvent(name: "composer-send", sessionID: sessionID)
                return await send(text: text, to: session.id ?? sessionID, now: now, using: model)
            },
            onEnqueue: { [model] text, now in
                recordLifecycleEvent(name: "composer-send", sessionID: sessionID)
                return await enqueue(text: text, to: session.id ?? sessionID, now: now, using: model)
            },
            onAddAttachment: { file in
                store.addAttachment(file, to: sessionID)
            },
            onRemoveAttachment: { id in
                store.removeAttachment(id: id, from: sessionID)
            },
            onRetryAttachment: { id in
                store.retryAttachment(id: id, sessionID: sessionID)
            },
            onStop: { [model] in
                await interrupt(sessionID: session.id ?? sessionID, using: model)
            },
            onModel: {
                dismissKeyboard()
                modelSheetPresented = true
            },
            onAllow: { approval in
                performApprovalDecision(approval, scope: .once)
            },
            onAllowSession: { approval in
                performApprovalDecision(approval, scope: .session)
            },
            onDeny: { approval in
                performApprovalDeny(approval)
            },
            questionState: questionState,
            canAnswerQuestions: store.supportsQuestions,
            onAnswer: { approval, answers in
                performQuestionAnswer(approval, answers: answers)
            },
            onSkip: { approval in
                performQuestionSkip(approval)
            },
            approvalControllerName: model.controllerName(for: store),
            allowsSessionScope: store.controllerInfo.kind != .stockade,
            terminalPaneAvailable: current.tmuxPane?.isEmpty == false,
            approvalAttachCommand: claudeAttachCommand(for: current),
            readOnlyLabel: readOnlyLabel(for: current)
        )
    }

    /// The controller's commands, plus `/sudo` on a writable Stockade session that advertises it.
    private func slashCommands(_ commands: [SlashCommand], for session: Session) -> [SlashCommand] {
        var available = composerCapabilities.canRunCommands ? commands : []
        if acceptsSudo(session, capabilities: store.controllerInfo.capabilities),
           !available.contains(where: { $0.command == "/sudo" }) {
            available.append(SlashCommand(command: "/sudo", description: "Toggle sudo mode"))
        }
        return available
    }

    /// Nil when the owning controller does not advertise `files`, which hides the download actions.
    private var transcriptDownload: (@MainActor @Sendable (FileEntry) async throws -> URL)? {
        guard store.supports(.files) else { return nil }
        return { entry in
            try await downloadFile(entry, sessionID: sessionID)
        }
    }

    @MainActor
    private func enqueue(text: String, to sessionID: String, now: Bool, using model: AppModel) async -> Result<QueuedNote, ActionError> {
        let result = await store.enqueueMessage(text: text, to: sessionID, now: now)
        switch result {
        case .success:
            sendAcceptedRevision += 1
        case .failure(let error):
            if shouldPresentSendError(error) {
                model.actionError = error
            }
        }
        return result
    }

    @MainActor
    private func send(text: String, to sessionID: String, now: Bool, using model: AppModel) async -> Result<MessageResult, ActionError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await store.sendComposer(text: text, to: sessionID, now: now)
        switch result {
        case .success(let message):
            sendAcceptedRevision += 1
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSlashCommand(trimmed) {
                dismissKeyboard()
            }
            if isSlashCommand(trimmed), let output = message.output, !output.isEmpty {
                commandOutput = CommandOutput(command: trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed, output: output)
            }
            if isSlashCommand(trimmed), message.queued == true {
                showCommandToast()
            }
            if let sudo = message.sudo {
                showToast(sudoToastText(sudo))
            }
        case .failure(let error):
            if shouldPresentSendError(error) {
                model.actionError = error
            }
        }
        return result
    }

    @MainActor
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @MainActor
    private func showCommandToast() {
        showToast("Runs when the current turn ends.")
    }

    @MainActor
    private func showToast(_ message: String) {
        commandToastTask?.cancel()
        commandToast = message
        commandToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            commandToast = nil
        }
    }

    private func shouldPresentSendError(_ error: ActionError) -> Bool {
        guard case .invalid(let message) = error else { return true }
        return message != "Remove or retry the failed attachment"
            && message != "Remove the file that is too large"
    }

    @MainActor
    private func interrupt(sessionID: String, using model: AppModel) async -> Result<Void, ActionError> {
        let result = await store.interrupt(sessionID: sessionID)
        if case .failure(let error) = result {
            model.actionError = error
        }
        return result
    }

    private var pendingApprovals: [Approval] {
        store.approvals(for: sessionID).sorted {
            ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast)
        }
    }

    private var approvalRequestIDs: [String] {
        pendingApprovals.compactMap(\.requestId)
    }

    private var pendingApprovalCount: Int {
        pendingApprovals.count
    }

    private func performApprovalDecision(_ approval: Approval, scope: ApprovalScope) {
        Task { @MainActor in
            let result = await store.allow(approval, scope: scope)
            switch result {
            case .success:
                allowFeedbackCount += 1
            case .failure(let error):
                if error != .waitingInTerminal { model.actionError = error }
            }
        }
    }

    private func performApprovalDeny(_ approval: Approval) {
        Task { @MainActor in
            let result = await store.deny(approval)
            switch result {
            case .success:
                denyFeedbackCount += 1
            case .failure(let error):
                if error != .waitingInTerminal { model.actionError = error }
            }
        }
    }

    private func performQuestionAnswer(_ approval: Approval, answers: [String: String]) {
        questionState.setError(nil, for: approval)
        Task { @MainActor in
            let result = await store.answerQuestion(approval, answers: answers)
            switch result {
            case .success:
                questionState.forget(approval)
                answeredFeedbackCount += 1
                showToast("Answered")
            case .failure(let error):
                handleQuestionFailure(error, for: approval)
            }
        }
    }

    private func performQuestionSkip(_ approval: Approval) {
        questionState.setError(nil, for: approval)
        Task { @MainActor in
            let result = await store.skipQuestion(approval)
            switch result {
            case .success:
                questionState.forget(approval)
                denyFeedbackCount += 1
            case .failure(let error):
                handleQuestionFailure(error, for: approval)
            }
        }
    }

    // A stale answer (410, hold expired) drops the card and refreshes state, so only a card that comes back can show an inline message.
    @MainActor
    private func handleQuestionFailure(_ error: ActionError, for approval: Approval) {
        switch error {
        case .answerInTerminal:
            questionState.setReadOnly(error.userMessage, for: approval)
        case .alreadyAnswered:
            questionState.forget(approval)
            model.actionError = error
        default:
            questionState.setError(error.userMessage, for: approval)
        }
    }

    private func announceNewApprovals(_ requestIDs: [String]) {
        let previousIDs = knownApprovalIDs
        knownApprovalIDs = Set(requestIDs)
        guard let newID = requestIDs.first(where: { !previousIDs.contains($0) }),
              let approval = pendingApprovals.first(where: { $0.requestId == newID }) else { return }
        if let header = approval.questions?.first?.header {
            AccessibilityNotification.Announcement("Question: \(header)").post()
        } else {
            AccessibilityNotification.Announcement("Approval needed: \(approval.toolName ?? "Tool")").post()
        }
    }

    private var toolSheetPresented: Binding<Bool> {
        Binding(
            get: { selectedTool != nil },
            set: { if !$0 { selectedTool = nil } }
        )
    }

    private var compactionSheetPresented: Binding<Bool> {
        Binding(
            get: { selectedCompaction != nil },
            set: { if !$0 { selectedCompaction = nil } }
        )
    }

    private var sessionLoadKey: SessionLoadKey {
        SessionLoadKey(
            sessionID: sessionID,
            hasSession: store.sessions[sessionID] != nil || store.sleeping.contains(where: { $0.id == sessionID }),
            isLive: store.sessions[sessionID]?.live == true
        )
    }

    private var destinationBinding: Binding<Bool> {
        Binding(
            get: { destination != nil },
            set: { isPresented in
                if !isPresented { destination = nil }
            }
        )
    }

    private func openSubagent(_ entry: SubagentEntry) {
        guard let agentID = entry.agentId, !agentID.isEmpty else { return }
        destination = SessionDestination(sessionID: sessionID, agentID: agentID)
    }

    private func openSubagentTranscript(_ selection: SubagentResultSelection) {
        let agentID = selection.subagent?.agentId ?? selection.entry.agentId
        guard let agentID, !agentID.isEmpty else { return }
        pendingSubagentDestination = SessionDestination(sessionID: sessionID, agentID: agentID)
        selectedSubagentResult = nil
    }

    private func presentPendingSubagentDestination() {
        guard let pendingSubagentDestination else { return }
        self.pendingSubagentDestination = nil
        destination = pendingSubagentDestination
    }

    private func openSubagentFromInspector(_ subagent: Subagent) {
        guard let agentID = subagent.agentId, !agentID.isEmpty else { return }
        pendingInspectorDestination = SessionDestination(sessionID: sessionID, agentID: agentID)
        inspectorPresented = false
    }

    private func openSubagentFromActivity(_ subagent: Subagent) {
        guard let agentID = subagent.agentId, !agentID.isEmpty else { return }
        pendingActivityDestination = SessionDestination(sessionID: sessionID, agentID: agentID)
        activityPresented = false
    }

    private func presentPendingActivityDestination() {
        guard let pendingActivityDestination else { return }
        self.pendingActivityDestination = nil
        destination = pendingActivityDestination
    }

    private func presentPendingInspectorDestination() {
        guard let pendingInspectorDestination else { return }
        self.pendingInspectorDestination = nil
        destination = pendingInspectorDestination
    }

    @MainActor
    private func downloadFile(_ entry: FileEntry, sessionID: String) async throws -> URL {
        let downloaded = try await store.downloadFile(
            sessionID: sessionID,
            name: entry.name ?? "download"
        )
        let originalName = URL(fileURLWithPath: entry.name ?? "download").lastPathComponent
        let fileName = originalName.isEmpty ? "download" : originalName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try downloaded.data.write(to: url, options: .atomic)
        return url
    }

    @ViewBuilder
    private func contentNavigation<Content: View>(
        name: String,
        session: Session,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isCompact {
            compactContentNavigation(name: name, session: session, content: content)
        } else {
            content()
                .safeAreaInset(edge: .top, spacing: 0) {
                    RegularDetailHeader(reservedText: approvalsElsewhereCount > 0 ? approvalsElsewhereText : nil) {
                        sessionTitle(name: name, session: session)
                    } trailing: {
                        sessionInfoButton(size: RegularHeaderMetrics.toggleSize)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                }
                .tint(.ccAccent)
                .background(.ccBackground)
        }
    }

    private func compactContentNavigation<Content: View>(
        name: String,
        session: Session,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if approvalsElsewhereCount > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onShowApprovalsElsewhere) {
                            Text(approvalsElsewhereText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.ccAmber)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .accessibilityIdentifier("approvals-elsewhere")
                        .accessibilityLabel(approvalsElsewhereAccessibilityLabel)
                    }
                }
                ToolbarItem(placement: .principal) {
                    sessionTitle(name: name, session: session)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    sessionInfoButton(size: nil)
                }
            }
            .tint(.ccAccent)
            .background(.ccBackground)
            .toolbarBackground(.ccBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    private func sessionTitle(name: String, session: Session) -> some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.sessionHeader)
        #endif
        return VStack(alignment: isCompact ? .center : .leading, spacing: 0) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("selected-session-name")
                .accessibilityValue(session.id ?? sessionID)
            SessionSubtitleView(session: session, controllerName: model.controllerName(for: store))
                .font(.caption)
                .foregroundStyle(.ccSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("selected-session-subtitle")
        }
    }

    private func sessionInfoButton(size: CGFloat?) -> some View {
        Button {
            if inspectorPresented {
                inspectorPresented = false
            } else {
                openInspector()
            }
        } label: {
            Image(systemName: "info.circle")
                .frame(width: size, height: size)
        }
        .accessibilityLabel("Session info")
        .accessibilityIdentifier("session-info")
    }

    @ViewBuilder
    private func inspectorContent() -> some View {
        if let session = store.openSession(sessionID)?.session {
            InspectorView(
                session: session,
                onInterrupt: interrupt,
                onCopySessionID: { UIPasteboard.general.string = sessionID },
                onApprovalMode: setApprovalMode,
                onSubagent: openSubagentFromInspector,
                canInterrupt: store.supports(.interrupt),
                canSetApprovalMode: store.supports(.mode)
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ccBackground)
        }
    }

    /// In large mode a sidebar that doesn't leave room moves first, so the inspector opens into the full width.
    private func openInspector() {
        if !isCompact { onRegularInspectorWillOpen() }
        inspectorPresented = true
    }

    private var compactInspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorPresented && isCompact },
            set: { presented in
                if !presented { inspectorPresented = false }
            }
        )
    }

    private var regularInspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorPresented && !isCompact },
            set: { presented in
                if !presented { inspectorPresented = false }
            }
        )
    }

    private func setApprovalMode(_ mode: ApprovalMode) {
        Task { @MainActor in
            let result = await store.setApprovalMode(sessionID: sessionID, mode: mode)
            if case .failure(let error) = result {
                model.actionError = error
            }
        }
    }

    private func isTranscriptCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        if let apiError = error as? APIError,
           case .transport(let urlError) = apiError {
            return urlError.code == .cancelled
        }
        return false
    }

    private func interrupt() {
        Task { @MainActor in
            let result = await store.interrupt(sessionID: sessionID)
            if case .failure(let error) = result {
                model.actionError = error
            }
        }
    }
}
