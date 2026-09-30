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
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onSettings) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .searchable(text: $searchText, prompt: "Search sessions")
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
                    frozen: connection.isFrozen,
                    onOpen: { onOpen(session) },
                    onAllow: onAllow,
                    onDeny: onDeny
                )
                .listRowBackground(Color.ccCard)
                .listRowSeparatorTint(.ccSeparator)
            }
        }
    }

    private var subtitle: String {
        subtitleOverride ?? nowSubtitle(total: sessions.count, needsYou: sessions.filter { $0.state == .needsYou }.count)
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
    let onOpen: () -> Void
    let onAllow: (Approval) -> Void
    let onDeny: (Approval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SessionGlyph(session: session, frozen: frozen)
                        .frame(width: 28, alignment: .center)
                    SessionText(session: session, now: now, approval: approval)
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
                .padding(.leading, 40)
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

    var body: some View {
        switch session.state {
        case .working:
            SpinnerGlyph(active: true, frozen: frozen)
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
    let now: Date
    let approval: Approval?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.name ?? "Untitled session")
                    .font(.headline)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.ccTertiary)
                    .fixedSize()
            }
            Text(meta)
                .font(.subheadline)
                .foregroundStyle(.ccSecondary)
                .lineLimit(1)
            Text(activity)
                .font(.footnote.weight(session.state == .needsYou ? .semibold : .regular))
                .foregroundStyle(session.state == .needsYou ? Color.ccAccent : Color.ccSecondary)
                .lineLimit(1)
        }
    }

    private var meta: String {
        let project = session.project ?? "unknown project"
        let state = compactState(sessionStateSegment(session, now: now))
        let context = formatContextUsage(session.usage)
        return [project, state, context].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var activity: String {
        if session.state == .needsYou {
            let tool = approval?.toolName ?? session.lastTool ?? "Tool"
            return "\(tool) command waiting"
        }
        if session.state == .working, session.toolRunning == true {
            return "Running \(activityLineText(session))"
        }
        return activityLineText(session)
    }

    private var relativeTime: String {
        let date = session.state == .idle ? session.idleSince : session.startedAt
        return compactState(formatDuration(elapsed(from: date)))
    }

    private func elapsed(from date: Date?) -> Double {
        guard let date else { return 0 }
        return max(0, now.timeIntervalSince(date) * 1000)
    }

    private func compactState(_ value: String) -> String {
        value.replacingOccurrences(of: " 0s", with: "")
    }
}
