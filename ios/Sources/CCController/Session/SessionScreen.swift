import CCKit
import Foundation
import QuickLook
import SwiftUI
import UIKit

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
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
    @State private var knownApprovalIDs: Set<String> = []

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        screen()
            .quickLookPreview($filePreviewURL)
        .sensoryFeedback(.success, trigger: allowFeedbackCount)
        .sensoryFeedback(.warning, trigger: denyFeedbackCount)
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
        .background {
            // TODO: move to navigationDestination once the split-view detail stack keeps the toolbar (see tasks/native-app.md Open)
            NavigationLink(isActive: destinationBinding) {
                if let destination {
                    SubagentScreen(
                        sessionID: destination.sessionID,
                        agentID: destination.agentID,
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
                  let sessionStore = model.store.openSession(key.sessionID) else { return }
            #if DEBUG || CC_PERF
            model.store.addDebugAttachments(model.debugAttachmentPaths, to: key.sessionID)
            #endif
            guard !sessionStore.isLoaded else { return }
            do {
                try await sessionStore.loadInitial()
            } catch {
                guard !isTranscriptCancellation(error) else { return }
                model.actionError = .network(error.localizedDescription)
            }
        }
        .onAppear {
            #if DEBUG || CC_PERF
            TranscriptPerformance.shared.beginScreenAppearance(sessionID: sessionID)
            model.store.addDebugAttachments(model.debugAttachmentPaths, to: sessionID)
            #endif
        }
        .onDisappear {
            guard destination == nil else { return }
            model.store.closeSession(sessionID)
        }
    }

    @ViewBuilder
    private func screen() -> some View {
        let _ = model.store.attachmentRevision
        if let sessionStore = model.store.openSession(sessionID) {
            contentNavigation(
                name: sessionStore.session.name ?? "Session",
                session: sessionStore.session
            ) {
                if sessionStore.isLoaded || !sessionStore.entries.isEmpty {
                    SessionTranscriptView(
                        sessionID: sessionID,
                        turns: sessionStore.turns,
                        rows: sessionStore.rows,
                        bottomStackConfiguration: bottomStackConfiguration(
                            for: sessionStore.session,
                            liveSession: model.store.sessions[sessionID],
                            transcriptEntries: sessionStore.entries
                        ),
                        queuedNotes: model.store.queuedNotes(for: sessionID),
                        liveSession: sessionStore.session,
                        subagents: sessionStore.session.subagents ?? [],
                        hasMoreEarlier: sessionStore.hasMoreEarlier,
                        loadEarlier: { try await sessionStore.loadEarlier() },
                        onTool: { selectedTool = $0 },
                        onSubagent: openSubagent,
                        onSubagentResult: { entry, subagent in
                            selectedSubagentResult = SubagentResultSelection(entry: entry, subagent: subagent)
                        },
                        onCompaction: { selectedCompaction = $0 },
                        downloadFile: { entry in
                            try await downloadFile(entry, sessionID: sessionID)
                        }
                    )
                    .environment(\.openInspector, { inspectorPresented = true })
                    .environment(\.openFilePreview, { filePreviewURL = $0 })
                } else {
                    ProgressView()
                        .accessibilityIdentifier("session-loading")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ccBackground)
                }
            }
            .sheet(isPresented: toolSheetPresented) {
                if let selectedTool {
                    ToolDetailSheet(tool: selectedTool)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
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
                if let session = model.store.openSession(sessionID)?.session {
                    ActivitySheet(session: session, onSubagent: openSubagentFromActivity)
                }
            }
        } else {
            ProgressView()
                .accessibilityIdentifier("session-loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ccBackground)
                .navigationTitle("Session")
                .navigationBarTitleDisplayMode(.inline)
        }
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
            composer: ComposerConfiguration(
                draft: ComposerDraft(
                    initialText: { model.store.draft(for: sessionID) },
                    onChange: { [model] text in model.store.setDraft(text, for: sessionID) }
                ),
                modelName: composerModelName(modelName),
                placeholder: current.state == .working ? "Queue a message" : "Message",
                isWorking: current.state == .working,
                hasTmuxPane: current.tmuxPane?.isEmpty == false
            ),
            statusSegments: formatTokenUsageSegments(current.usage),
            activitySession: current,
            onActivity: { activityPresented = true },
            slashCommands: commands,
            attachments: (model.store.attachments[sessionID] ?? []).map(ComposerAttachment.init(item:)),
            attachmentNotice: model.store.attachmentNotices[sessionID],
            approvals: pendingApprovals,
            deciding: model.store.deciding,
            onSend: { [model] text, now in
                await send(text: text, to: session.id ?? sessionID, now: now, using: model)
            },
            onAddAttachment: { [model] file in
                model.store.addAttachment(file, to: sessionID)
            },
            onRemoveAttachment: { [model] id in
                model.store.removeAttachment(id: id, from: sessionID)
            },
            onRetryAttachment: { [model] id in
                model.store.retryAttachment(id: id, sessionID: sessionID)
            },
            onStop: { [model] in
                await interrupt(sessionID: session.id ?? sessionID, using: model)
            },
            onModel: { inspectorPresented = true },
            onAllow: { approval in
                performApprovalDecision(approval, scope: .once)
            },
            onAllowSession: { approval in
                performApprovalDecision(approval, scope: .session)
            },
            onDeny: { approval in
                performApprovalDeny(approval)
            }
        )
    }

    @MainActor
    private func send(text: String, to sessionID: String, now: Bool, using model: AppModel) async -> Result<Void, ActionError> {
        let result = await model.store.sendComposer(text: text, to: sessionID, now: now)
        if case .failure(let error) = result, shouldPresentSendError(error) {
            model.actionError = error
        }
        return result
    }

    private func shouldPresentSendError(_ error: ActionError) -> Bool {
        guard case .invalid(let message) = error else { return true }
        return message != "Remove or retry the failed attachment"
            && message != "Remove the file that is too large"
    }

    @MainActor
    private func interrupt(sessionID: String, using model: AppModel) async -> Result<Void, ActionError> {
        let result = await model.store.interrupt(sessionID: sessionID)
        if case .failure(let error) = result {
            model.actionError = error
        }
        return result
    }

    private var pendingApprovals: [Approval] {
        model.store.approvals(for: sessionID).sorted {
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
            let result = await model.store.allow(approval, scope: scope)
            switch result {
            case .success:
                allowFeedbackCount += 1
            case .failure(let error):
                model.actionError = error
            }
        }
    }

    private func performApprovalDeny(_ approval: Approval) {
        Task { @MainActor in
            let result = await model.store.deny(approval)
            switch result {
            case .success:
                denyFeedbackCount += 1
            case .failure(let error):
                model.actionError = error
            }
        }
    }

    private func announceNewApprovals(_ requestIDs: [String]) {
        let previousIDs = knownApprovalIDs
        knownApprovalIDs = Set(requestIDs)
        guard let newID = requestIDs.first(where: { !previousIDs.contains($0) }),
              let approval = pendingApprovals.first(where: { $0.requestId == newID }) else { return }
        AccessibilityNotification.Announcement("Approval needed: \(approval.toolName ?? "Tool")").post()
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
            hasSession: model.store.sessions[sessionID] != nil,
            isLive: model.store.sessions[sessionID]?.live == true
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
        let downloaded = try await model.store.downloadFile(
            sessionID: sessionID,
            name: entry.name ?? "download"
        )
        let originalName = URL(fileURLWithPath: entry.name ?? "download").lastPathComponent
        let fileName = originalName.isEmpty ? "download" : originalName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try downloaded.data.write(to: url, options: .atomic)
        return url
    }

    private func contentNavigation<Content: View>(
        name: String,
        session: Session,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    #if CC_PERF
                    let _ = PerfCounters.shared.hit(.sessionHeader)
                    #endif
                    VStack(spacing: 0) {
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityIdentifier("selected-session-name")
                        SessionSubtitleView(session: session)
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("selected-session-subtitle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        inspectorPresented.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Session info")
                    .accessibilityIdentifier("session-info")
                }
            }
            .tint(.ccAccent)
            .background(.ccBackground)
    }

    @ViewBuilder
    private func inspectorContent() -> some View {
        if let session = model.store.openSession(sessionID)?.session {
            InspectorView(
                session: session,
                onInterrupt: interrupt,
                onCopySessionID: { UIPasteboard.general.string = sessionID },
                onApprovalMode: setApprovalMode,
                onSubagent: openSubagentFromInspector
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ccBackground)
        }
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
            let result = await model.store.setApprovalMode(sessionID: sessionID, mode: mode)
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
            let result = await model.store.interrupt(sessionID: sessionID)
            if case .failure(let error) = result {
                model.actionError = error
            }
        }
    }
}
