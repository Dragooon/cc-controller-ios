import CCKit
import SwiftUI

struct SessionsListView: View {
    enum Connection: Equatable {
        case live
        case offline(updatedAt: Date)
        case unreadable(updatedAt: Date)
        case reconnecting

        var isFrozen: Bool {
            switch self {
            case .offline, .unreadable, .reconnecting: true
            case .live: false
            }
        }
    }

    let sessions: [Session]
    let sleeping: [SleepingSession]
    let waking: Set<String>
    let approvals: [Approval]
    let deciding: Set<String>
    let connection: Connection
    let subtitleOverride: String?
    let notice: String?
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
    let onNewSession: () -> Void
    let onWake: (SleepingSession) -> Void
    let onCopyAttachCommand: (SleepingSession) -> Void

    @State private var searchText = ""

    init(
        sessions: [Session],
        sleeping: [SleepingSession] = [],
        waking: Set<String> = [],
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        connection: Connection = .live,
        subtitleOverride: String? = nil,
        notice: String? = nil,
        onSessionsLoaded: @escaping () async -> Void = {},
        onOpen: @escaping (Session) -> Void = { _ in },
        onAllow: @escaping (Approval) -> Void = { _ in },
        onDeny: @escaping (Approval) -> Void = { _ in },
        onRetry: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {},
        onInterrupt: @escaping (Session) -> Void = { _ in },
        onSetApprovalMode: @escaping (Session, ApprovalMode) -> Void = { _, _ in },
        onCopySessionID: @escaping (Session) -> Void = { _ in },
        onNewSession: @escaping () -> Void = {},
        onWake: @escaping (SleepingSession) -> Void = { _ in },
        onCopyAttachCommand: @escaping (SleepingSession) -> Void = { _ in }
    ) {
        self.sessions = sessions
        self.sleeping = sleeping
        self.waking = waking
        self.approvals = approvals
        self.deciding = deciding
        self.connection = connection
        self.subtitleOverride = subtitleOverride
        self.notice = notice
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
        self.onNewSession = onNewSession
        self.onWake = onWake
        self.onCopyAttachCommand = onCopyAttachCommand
    }

    private var filteredSessions: [Session] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || ($0.project ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredSleeping: [SleepingSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sleeping }
        return sleeping.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || $0.project.localizedCaseInsensitiveContains(query)
        }
    }

    private var needsYou: [Session] { filteredSessions.filter { sessionActivity($0) == .needsYou } }
    private var working: [Session] {
        filteredSessions.filter {
            switch sessionActivity($0) {
            case .working, .background: true
            case .needsYou, .idle: false
            }
        }
    }
    private var idle: [Session] { filteredSessions.filter { sessionActivity($0) == .idle } }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Sessions")
                .navigationSubtitle(subtitle ?? "")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onNewSession) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New session")
                        .accessibilityIdentifier("new-session")
                    }
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
        if sessions.isEmpty && sleeping.isEmpty {
            ContentUnavailableView {
                Label("No sessions", systemImage: "terminal")
            } description: {
                Text("No Claude Code sessions are running on this Mac.")
            } actions: {
                Button("New session", action: onNewSession)
                    .accessibilityIdentifier("empty-new-session")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ccBackground)
        } else {
            List {
                if let notice {
                    Section {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                sessionSection("Needs you", sessions: needsYou)
                sessionSection("Working", sessions: working)
                sessionSection("Idle", sessions: idle)
                sleepingSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.ccBackground)
            .animation(.smooth, value: listAnimationKey)
        }
    }

    @ViewBuilder
    private var sleepingSection: some View {
        if !filteredSleeping.isEmpty {
            Section("Asleep") {
                ForEach(filteredSleeping) { session in
                    SleepingSessionRow(
                        session: session,
                        isWaking: waking.contains(session.id),
                        onWake: { onWake(session) },
                        onCopyAttachCommand: { onCopyAttachCommand(session) }
                    )
                    .listRowBackground(Color.ccCard)
                    .listRowSeparatorTint(.ccSeparator)
                }
            }
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
        } + filteredSleeping.map { "sleeping:\($0.id):\(waking.contains($0.id))" }
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
            case .unreadable:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.ccAccent)
                Text("Can't read the Mac's reply · updated \(formatTime(.now, timeZone: Self.sydney, locale: Self.english))")
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
        case .unreadable: "Can't read the Mac's reply"
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
            .accessibilityValue(activityStateLabel)

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

    private var activityStateLabel: String {
        switch sessionActivity(session) {
        case .needsYou: "needs_you"
        case .working: "working"
        case .background: "background"
        case .idle: "idle"
        }
    }

    private func isDeciding(_ approval: Approval) -> Bool {
        guard let key = approvalDecisionKey(approval) else { return false }
        return deciding.contains(key)
    }
}

private struct SleepingSessionRow: View {
    let session: SleepingSession
    let isWaking: Bool
    let onWake: () -> Void
    let onCopyAttachCommand: () -> Void

    var body: some View {
        Button(action: onWake) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if isWaking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28)
                } else {
                    Image(systemName: "moon.zzz")
                        .font(.title3)
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(2)
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.ccLabel)
            .opacity(0.58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sleeping-session-\(session.id)")
        .accessibilityValue(isWaking ? "Waking" : "asleep")
        .contextMenu {
            Button("Copy attach command", action: onCopyAttachCommand)
        }
        .padding(.vertical, 7)
    }

    private var displayName: String {
        let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? session.project : name
    }

    private var meta: String {
        let status = isWaking ? "waking…" : "asleep \(formatListDuration(max(0, Date().timeIntervalSince(session.lastActiveAt) * 1000)))"
        return session.project.localizedCaseInsensitiveCompare(displayName) == .orderedSame
            ? status
            : "\(session.project) · \(status)"
    }
}

private struct SessionGlyph: View {
    let session: Session
    let frozen: Bool
    let dimmed: Bool

    var body: some View {
        switch sessionActivity(session) {
        case .working, .background:
            SpinnerGlyph(active: true, frozen: frozen, dimmed: dimmed)
                .font(.title3.weight(.medium))
                .accessibilityHidden(true)
        case .needsYou:
            Text("●")
                .font(.title3.weight(.medium))
                .foregroundStyle(.ccAccent)
        case .idle:
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
