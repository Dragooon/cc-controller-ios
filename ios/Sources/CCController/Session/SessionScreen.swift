import CCKit
import Foundation
import SwiftUI

struct SessionScreen: View {
    let sessionID: String
    @Bindable var model: AppModel
    @State private var selectedTool: ToolEntry?
    @State private var selectedCompaction: CompactionEntry?
    @State private var allowFeedbackCount = 0
    @State private var denyFeedbackCount = 0
    @State private var knownApprovalIDs: Set<String> = []

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
        .task(id: sessionID) {
            guard let sessionStore = model.store.openSession(sessionID) else { return }
            do {
                try await sessionStore.loadInitial()
            } catch {
                model.actionError = .network(error.localizedDescription)
            }
        }
        .onDisappear {
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
                        onCompaction: { selectedCompaction = $0 },
                        downloadFile: { entry in
                            try await downloadFile(entry, sessionID: sessionID)
                        }
                    )
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
            }
            .tint(.ccAccent)
            .background(.ccBackground)
    }
}
