import CCKit
import SwiftUI

struct SessionsListView: View {
    enum Connection: Equatable {
        case live
        case offline(updatedAt: Date)
        case reconnecting

        var isFrozen: Bool {
            switch self {
            case .offline, .reconnecting: true
            case .live: false
            }
        }
    }

    let sessions: [Session]
    let approvals: [Approval]
    let deciding: Set<String>
    let connection: Connection
    let subtitleOverride: String?
    let onSessionsLoaded: () async -> Void
    let onOpen: (Session) -> Void
    let onAllow: (Approval) -> Void
    let onDeny: (Approval) -> Void
    let onRetry: () -> Void
    let onSettings: () -> Void
    let onRefresh: () async -> Void
    let onInterrupt: (Session) -> Void
    let onSetApprovalMode: (Session, ApprovalMode) -> Void
    let onCopySessionID: (Session) -> Void

    @State private var searchText = ""

    init(
        sessions: [Session],
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        connection: Connection = .live,
        subtitleOverride: String? = nil,
        onSessionsLoaded: @escaping () async -> Void = {},
        onOpen: @escaping (Session) -> Void = { _ in },
        onAllow: @escaping (Approval) -> Void = { _ in },
        onDeny: @escaping (Approval) -> Void = { _ in },
        onRetry: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {},
        onInterrupt: @escaping (Session) -> Void = { _ in },
        onSetApprovalMode: @escaping (Session, ApprovalMode) -> Void = { _, _ in },
        onCopySessionID: @escaping (Session) -> Void = { _ in }
    ) {
        self.sessions = sessions
        self.approvals = approvals
        self.deciding = deciding
        self.connection = connection
        self.subtitleOverride = subtitleOverride
        self.onSessionsLoaded = onSessionsLoaded
        self.onOpen = onOpen
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onRetry = onRetry
        self.onSettings = onSettings
        self.onRefresh = onRefresh
        self.onInterrupt = onInterrupt
        self.onSetApprovalMode = onSetApprovalMode
        self.onCopySessionID = onCopySessionID
    }

    private var filteredSessions: [Session] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || ($0.project ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var needsYou: [Session] { filteredSessions.filter { $0.state == .needsYou } }
    private var working: [Session] { filteredSessions.filter { $0.state == .working } }
    private var idle: [Session] { filteredSessions.filter { $0.state == .idle } }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Sessions")
                .navigationSubtitle(subtitle ?? "")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onSettings) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .searchable(text: $searchText, prompt: "Search sessions")
                .searchToolbarBehavior(.minimize)
                .refreshable { await onRefresh() }
                .safeAreaBar(edge: .top, spacing: 8) {
                    if case .live = connection {
                        EmptyView()
                    } else {
                        ConnectionCapsule(connection: connection, onRetry: onRetry)
                    }
                }
        }
        .tint(.ccAccent)
        .background(.ccBackground)
        .task(id: sessions.isEmpty) {
            guard !sessions.isEmpty else { return }
            await onSessionsLoaded()
        }
    }

    @ViewBuilder
    private var list: some View {
        if sessions.isEmpty {
            ContentUnavailableView(
                "No sessions",
                systemImage: "terminal",
                description: Text("No Claude Code sessions are running on this Mac.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ccBackground)
        } else {
            List {
                sessionSection("Needs you", sessions: needsYou)
                sessionSection("Working", sessions: working)
                sessionSection("Idle", sessions: idle)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.ccBackground)
            .animation(.smooth, value: listAnimationKey)
        }
    }

    @ViewBuilder
    private func sessionSection(_ title: String, sessions: [Session]) -> some View {
        Section(title) {
            ForEach(sessions, id: \.id) { session in
                SessionRow(
                    session: session,
                    approval: approval(for: session),
                    deciding: deciding,
                    frozen: connection.isFrozen,
                    dimmed: connection.isFrozen,
                    onOpen: { onOpen(session) },
                    onAllow: onAllow,
                    onDeny: onDeny,
                    onInterrupt: { onInterrupt(session) },
                    onSetApprovalMode: { mode in onSetApprovalMode(session, mode) },
                    onCopySessionID: { onCopySessionID(session) }
                )
                .listRowBackground(Color.ccCard)
                .listRowSeparatorTint(.ccSeparator)
            }
        }
    }

    private var subtitle: String? {
        subtitleOverride ?? sessionsSubtitle(sessions)
    }

    private var listAnimationKey: [String] {
        filteredSessions.map { session in
            [
                session.id ?? "",
                session.state?.rawValue ?? "",
                approval(for: session)?.requestId ?? "",
            ].joined(separator: ":")
        }
    }

    private func approval(for session: Session) -> Approval? {
        if let pending = session.pending?.first { return pending }
        return approvals.first { $0.sessionId == session.id }
    }
}

private struct ConnectionCapsule: View {
    let connection: SessionsListView.Connection
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch connection {
            case .offline:
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.ccAccent)
                Text("Can't reach the Mac · updated \(formatTime(.now, timeZone: Self.sydney, locale: Self.english))")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Retry", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
            case .reconnecting:
                ProgressView()
                    .controlSize(.small)
                    .tint(.ccAccent)
                Text("Reconnecting…")
                    .lineLimit(1)
                Spacer(minLength: 4)
            case .live:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(.ccSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusLabel)
    }

    private var statusLabel: String {
        switch connection {
        case .offline: "Can't reach the Mac"
        case .reconnecting: "Reconnecting"
        case .live: "Connected"
        }
    }

    private static let sydney = TimeZone(identifier: "Australia/Sydney")!
    private static let english = Locale(identifier: "en_AU")
}

private struct SessionRow: View {
    let session: Session
    let approval: Approval?
    let deciding: Set<String>
    let frozen: Bool
    let dimmed: Bool
    let onOpen: () -> Void
    let onAllow: (Approval) -> Void
    let onDeny: (Approval) -> Void
    let onInterrupt: () -> Void
    let onSetApprovalMode: (ApprovalMode) -> Void
    let onCopySessionID: () -> Void

    @ScaledMetric(relativeTo: .title3) private var glyphWidth = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SessionGlyph(session: session, frozen: frozen, dimmed: dimmed)
                        .frame(width: glyphWidth, alignment: .center)
                    SessionText(session: session, approval: approval)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(session.id.map { "session-\($0)" } ?? "session-")
            .accessibilityValue(session.state?.rawValue ?? "unknown")

            if let approval {
                ApprovalCard(
                    approval: approval,
                    style: .compact,
                    onOpen: onOpen,
                    onAllow: { onAllow(approval) },
                    onAllowSession: {},
                    onDeny: { onDeny(approval) }
                )
                .disabled(isDeciding(approval))
            }
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Open", action: onOpen)
            if session.tmuxPane != nil {
                Button("Interrupt", role: .destructive, action: onInterrupt)
            }
            Menu("Approvals mode") {
                Button("Auto") { onSetApprovalMode(.auto) }
                Button("Remote") { onSetApprovalMode(.remote) }
                Button("Terminal") { onSetApprovalMode(.terminal) }
            }
            Button("Copy session ID", action: onCopySessionID)
        }
    }

    private func isDeciding(_ approval: Approval) -> Bool {
        guard let key = approvalDecisionKey(approval) else { return false }
        return deciding.contains(key)
    }
}

private struct SessionGlyph: View {
    let session: Session
    let frozen: Bool
    let dimmed: Bool

    var body: some View {
        switch session.state {
        case .working:
            SpinnerGlyph(active: true, frozen: frozen, dimmed: dimmed)
                .font(.title3.weight(.medium))
                .accessibilityHidden(true)
        case .needsYou:
            Text("●")
                .font(.title3.weight(.medium))
                .foregroundStyle(.ccAccent)
        default:
            Text("○")
                .font(.title3.weight(.medium))
                .foregroundStyle(.ccTertiary)
        }
    }
}

private struct SessionText: View {
    let session: Session
    let approval: Approval?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.name ?? "Untitled session")
                .font(.headline)
                .foregroundStyle(.ccLabel)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            meta

            if !activity.isEmpty {
                Text(activity)
                    .font(.footnote.weight(session.state == .needsYou ? .semibold : .regular))
                    .foregroundStyle(session.state == .needsYou ? Color.ccAccent : Color.ccSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: some View {
        Group {
            if shouldWrapMeta {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project ?? "unknown project")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    SessionStateSegmentView(session: session)
                        .lineLimit(dynamicTypeSize >= .accessibility1 ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.project ?? "unknown project")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    SessionStateSegmentView(session: session)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.ccSecondary)
    }



    private var shouldWrapMeta: Bool {
        (session.project ?? "").count > 10 || dynamicTypeSize >= .accessibility1
    }

    private var activity: String {
        if session.state == .needsYou, approval != nil { return "" }
        if session.state == .needsYou {
            return "\(session.lastTool ?? "Tool") command waiting"
        }
        if session.state == .working, session.toolRunning == true {
            return "Running \(activityLineText(session))"
        }
        return activityLineText(session)
    }

}
