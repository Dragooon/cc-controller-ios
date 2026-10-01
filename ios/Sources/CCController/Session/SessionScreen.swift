import CCKit
import Foundation
import SwiftUI
import UIKit

struct SessionScreen: View {
    private struct SessionDestination: Hashable {
        let sessionID: String
        let agentID: String
    }

    let sessionID: String
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTool: ToolEntry?
    @State private var selectedCompaction: CompactionEntry?
    @State private var inspectorPresented = false
    @State private var destination: SessionDestination?
    @State private var pendingInspectorDestination: SessionDestination?
    @State private var allowFeedbackCount = 0
    @State private var denyFeedbackCount = 0
    @State private var knownApprovalIDs: Set<String> = []

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            screen(now: context.date)
        }
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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                inspectorContent(now: context.date)
            }
        }
        .inspector(isPresented: regularInspectorBinding) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                inspectorContent(now: context.date)
            }
        }
        .background {
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
        .task(id: sessionID) {
            do {
                try await loadSession()
            } catch is CancellationError {
                return
            } catch {
                model.actionError = .network(error.localizedDescription)
            }
        }
        .onDisappear {
            guard destination == nil else { return }
            model.store.closeSession(sessionID)
        }
    }

    @ViewBuilder
    private func screen(now: Date) -> some View {
        if let sessionStore = model.store.openSession(sessionID) {
            contentNavigation(
                name: sessionStore.session.name ?? "Session",
                subtitle: sessionDetailSubtitle(sessionStore.session, now: now)
            ) {
                if sessionStore.isLoaded {
                    SessionTranscriptView(
                        turns: sessionStore.turns,
                        now: now,
                        bottomStackConfiguration: BottomStackConfiguration(
                            approvals: pendingApprovals,
                            deciding: model.store.deciding,
                            onAllow: { approval in
                                performApprovalDecision(approval, scope: .once)
                            },
                            onAllowSession: { approval in
                                performApprovalDecision(approval, scope: .session)
                            },
                            onDeny: { approval in
                                performApprovalDeny(approval)
                            }
                        ),
                        subagents: sessionStore.session.subagents ?? [],
                        hasMoreEarlier: sessionStore.hasMoreEarlier,
                        loadEarlier: { try await sessionStore.loadEarlier() },
                        onTool: { selectedTool = $0 },
                        onSubagent: openSubagent,
                        onCompaction: { selectedCompaction = $0 },
                        downloadFile: { entry in
                            try await downloadFile(entry, sessionID: sessionID)
                        }
                    )
                    .environment(\.openInspector, { inspectorPresented = true })
                } else {
                    ProgressView()
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
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ccBackground)
                .navigationTitle("Session")
                .navigationBarTitleDisplayMode(.inline)
        }
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

    private func loadSession() async throws {
        while !Task.isCancelled {
            guard let sessionStore = model.store.openSession(sessionID) else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            guard !sessionStore.isLoaded else { return }
            try await sessionStore.loadInitial()
            if sessionStore.isLoaded { return }
            try await Task.sleep(for: .milliseconds(100))
        }
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

    private func openSubagentFromInspector(_ subagent: Subagent) {
        guard let agentID = subagent.agentId, !agentID.isEmpty else { return }
        pendingInspectorDestination = SessionDestination(sessionID: sessionID, agentID: agentID)
        inspectorPresented = false
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
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityIdentifier("selected-session-name")
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
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
    private func inspectorContent(now: Date) -> some View {
        if let session = model.store.openSession(sessionID)?.session {
            InspectorView(
                session: session,
                now: now,
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

    private func interrupt() {
        Task { @MainActor in
            let result = await model.store.interrupt(sessionID: sessionID)
            if case .failure(let error) = result {
                model.actionError = error
            }
        }
    }
}
