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
    let connection: Connection
    let now: Date
    let subtitleOverride: String?
    let freezeWorkingGlyphs: Bool
    let onOpen: (Session) -> Void
    let onAllow: (Approval) -> Void
    let onDeny: (Approval) -> Void
    let onRetry: () -> Void
    let onSettings: () -> Void

    @State private var searchText = ""

    init(
        sessions: [Session],
        approvals: [Approval] = [],
        connection: Connection = .live,
        now: Date = .now,
        subtitleOverride: String? = nil,
        freezeWorkingGlyphs: Bool = false,
        onOpen: @escaping (Session) -> Void = { _ in },
        onAllow: @escaping (Approval) -> Void = { _ in },
        onDeny: @escaping (Approval) -> Void = { _ in },
        onRetry: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {}
    ) {
        self.sessions = sessions
        self.approvals = approvals
        self.connection = connection
        self.now = now
        self.subtitleOverride = subtitleOverride
        self.freezeWorkingGlyphs = freezeWorkingGlyphs
        self.onOpen = onOpen
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onRetry = onRetry
        self.onSettings = onSettings
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
        NavigationSplitView {
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
                .safeAreaBar(edge: .top, spacing: 8) {
                    if case .live = connection {
                        EmptyView()
                    } else {
                        ConnectionCapsule(connection: connection, now: now, onRetry: onRetry)
                    }
                }
        } detail: {
            EmptyView()
        }
        .tint(.ccAccent)
        .background(.ccBackground)
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
        }
    }

    @ViewBuilder
    private func sessionSection(_ title: String, sessions: [Session]) -> some View {
        Section(title) {
            ForEach(sessions, id: \.id) { session in
                SessionRow(
                    session: session,
                    approval: approval(for: session),
                    now: now,
                    frozen: connection.isFrozen || freezeWorkingGlyphs,
                    frozenColor: connection.isFrozen ? .ccTertiary : .ccAccent,
                    onOpen: { onOpen(session) },
                    onAllow: onAllow,
                    onDeny: onDeny
                )
                .listRowBackground(Color.ccCard)
                .listRowSeparatorTint(.ccSeparator)
            }
        }
    }

    private var subtitle: String? {
        subtitleOverride ?? sessionsSubtitle(sessions)
    }

    private func approval(for session: Session) -> Approval? {
        if let pending = session.pending?.first { return pending }
        return approvals.first { $0.sessionId == session.id }
    }
}

private struct ConnectionCapsule: View {
    let connection: SessionsListView.Connection
    let now: Date
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch connection {
            case .offline:
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.ccAccent)
                Text("Can't reach the Mac · updated \(formatTime(now, timeZone: Self.sydney, locale: Self.english))")
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
    let now: Date
    let frozen: Bool
    let frozenColor: Color
    let onOpen: () -> Void
    let onAllow: (Approval) -> Void
    let onDeny: (Approval) -> Void

    @ScaledMetric(relativeTo: .title3) private var glyphWidth = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SessionGlyph(session: session, frozen: frozen, frozenColor: frozenColor)
                        .frame(width: glyphWidth, alignment: .center)
                    SessionText(session: session, approval: approval, now: now)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let approval {
                ApprovalCard(
                    approval: approval,
                    style: .compact,
                    now: now,
                    onAllow: { onAllow(approval) },
                    onAllowSession: {},
                    onDeny: { onDeny(approval) }
                )
            }
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Interrupt", role: .destructive) {}
            Menu("Approvals mode") {
                Button("Auto") {}
                Button("Remote") {}
                Button("Terminal") {}
            }
            Button("Copy session ID") {}
        }
    }
}

private struct SessionGlyph: View {
    let session: Session
    let frozen: Bool
    let frozenColor: Color

    var body: some View {
        switch session.state {
        case .working:
            SpinnerGlyph(active: true, frozen: frozen, frozenColor: frozenColor)
                .font(.title3.weight(.medium))
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
    let now: Date

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
    }

    private var meta: some View {
        ViewThatFits(in: .horizontal) {
            metaInline
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project ?? "unknown project")
                    .lineLimit(1)
                    .truncationMode(.middle)
                metaState
            }
        }
        .font(.subheadline)
        .foregroundStyle(.ccSecondary)
    }

    private var metaInline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(session.project ?? "unknown project")
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)
            metaState
            Spacer(minLength: 0)
        }
    }

    private var metaState: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(" · \(sessionStateSegment(session))")
                .fixedSize()
                .layoutPriority(1)
            let context = formatContextUsage(session.usage)
            if !context.isEmpty {
                Text(" · \(context)")
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
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

    private func sessionStateSegment(_ session: Session) -> String {
        let value = CCKit.sessionStateSegment(session, now: now)
        return value.replacingOccurrences(of: " 0s", with: "")
    }
}
