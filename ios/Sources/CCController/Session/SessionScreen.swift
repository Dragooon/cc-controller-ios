import CCKit
import Foundation
import SwiftUI

struct SessionScreen: View {
    let sessionID: String
    @Bindable var model: AppModel
    @State private var selectedTool: ToolEntry?
    @State private var selectedCompaction: CompactionEntry?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            screen(now: context.date)
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
