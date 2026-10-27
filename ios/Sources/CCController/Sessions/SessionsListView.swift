import CCKit
import SwiftUI

/// One controller's slice of the sessions list.
struct SessionsListController: Identifiable {
    let id: ControllerID
    let name: String
    let connection: SessionsListView.Connection
    let signInNeeded: Bool
    let sessions: [Session]
    let sleeping: [SleepingSession]
    let approvals: [Approval]
    let deciding: Set<String>
    let capabilities: Set<ControllerCapability>

    init(
        id: ControllerID,
        name: String,
        connection: SessionsListView.Connection = .live,
        signInNeeded: Bool = false,
        sessions: [Session],
        sleeping: [SleepingSession] = [],
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        capabilities: Set<ControllerCapability> = ControllerCapability.all
    ) {
        self.id = id
        self.name = name
        self.connection = connection
        self.signInNeeded = signInNeeded
        self.sessions = sessions
        self.sleeping = sleeping
        self.approvals = approvals
        self.deciding = deciding
        self.capabilities = capabilities
    }

    func approval(for session: Session) -> Approval? {
        if let pending = session.pending?.first { return pending }
        return approvals.first { $0.sessionId == session.id }
    }
}

/// A key for a sleeping session that is unique across controllers.
func sleepingSessionKey(controllerID: ControllerID, sessionID: String) -> String {
    "\(controllerID.rawValue)/\(sessionID)"
}

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

    let controllers: [SessionsListController]
    /// Keys from `sleepingSessionKey(controllerID:sessionID:)`.
    let waking: Set<String>
    let subtitleOverride: String?
    let notice: String?
    let canCreateSession: Bool
    let onSessionsLoaded: () async -> Void
    let onOpen: (ControllerID, Session) -> Void
    let onAllow: (ControllerID, Approval) -> Void
    let onDeny: (ControllerID, Approval) -> Void
    let onRetry: (ControllerID) -> Void
    let onSignIn: (ControllerID) -> Void
    let onSettings: () -> Void
    let onRefresh: () async -> Void
    let onInterrupt: (ControllerID, Session) -> Void
    let onSetApprovalMode: (ControllerID, Session, ApprovalMode) -> Void
    let onCopySessionID: (Session) -> Void
    let onNewSession: () -> Void
    let onWake: (ControllerID, SleepingSession) -> Void
    let onCopyAttachCommand: (SleepingSession) -> Void

    @State private var searchText = ""
    @State private var isSearchPresented = false

    init(
        controllers: [SessionsListController],
        waking: Set<String> = [],
        subtitleOverride: String? = nil,
        notice: String? = nil,
        canCreateSession: Bool = true,
        onSessionsLoaded: @escaping () async -> Void = {},
        onOpen: @escaping (ControllerID, Session) -> Void = { _, _ in },
        onAllow: @escaping (ControllerID, Approval) -> Void = { _, _ in },
        onDeny: @escaping (ControllerID, Approval) -> Void = { _, _ in },
        onRetry: @escaping (ControllerID) -> Void = { _ in },
        onSignIn: @escaping (ControllerID) -> Void = { _ in },
        onSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {},
        onInterrupt: @escaping (ControllerID, Session) -> Void = { _, _ in },
        onSetApprovalMode: @escaping (ControllerID, Session, ApprovalMode) -> Void = { _, _, _ in },
        onCopySessionID: @escaping (Session) -> Void = { _ in },
        onNewSession: @escaping () -> Void = {},
        onWake: @escaping (ControllerID, SleepingSession) -> Void = { _, _ in },
        onCopyAttachCommand: @escaping (SleepingSession) -> Void = { _ in }
    ) {
        self.controllers = controllers
        self.waking = waking
        self.subtitleOverride = subtitleOverride
        self.notice = notice
        self.canCreateSession = canCreateSession
        self.onSessionsLoaded = onSessionsLoaded
        self.onOpen = onOpen
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onRetry = onRetry
        self.onSignIn = onSignIn
        self.onSettings = onSettings
        self.onRefresh = onRefresh
        self.onInterrupt = onInterrupt
        self.onSetApprovalMode = onSetApprovalMode
        self.onCopySessionID = onCopySessionID
        self.onNewSession = onNewSession
        self.onWake = onWake
        self.onCopyAttachCommand = onCopyAttachCommand
    }

    /// The single-controller form, used by the mocks.
    init(
        sessions: [Session],
        sleeping: [SleepingSession] = [],
        approvals: [Approval] = [],
        deciding: Set<String> = [],
        connection: Connection = .live,
        subtitleOverride: String? = nil,
        notice: String? = nil
    ) {
        self.init(
            controllers: [
                SessionsListController(
                    id: .mac,
                    name: "Mac",
                    connection: connection,
                    sessions: sessions,
                    sleeping: sleeping,
                    approvals: approvals,
                    deciding: deciding
                ),
            ],
            subtitleOverride: subtitleOverride,
            notice: notice
        )
    }

    private var isMultiController: Bool { controllers.count >= 2 }
    private var allSessions: [Session] { controllers.flatMap(\.sessions) }
    private var hasAnySessions: Bool { controllers.contains { !$0.sessions.isEmpty || !$0.sleeping.isEmpty } }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func filteredSessions(_ controller: SessionsListController) -> [Session] {
        guard !query.isEmpty else { return controller.sessions }
        return controller.sessions.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || ($0.project ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func filteredSleeping(_ controller: SessionsListController) -> [SleepingSession] {
        guard !query.isEmpty else { return controller.sleeping }
        return controller.sleeping.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(query)
                || $0.project.localizedCaseInsensitiveContains(query)
        }
    }

    private var sessionItems: [ControllerSessionItem] {
        controllers.flatMap { controller in
            filteredSessions(controller).map { ControllerSessionItem(controller: controller, session: $0) }
        }
    }

    private var needsYouItems: [ControllerSessionItem] {
        sortSessionItems(sessionItems.filter { sessionActivity($0.session) == .needsYou })
    }

    private var recentItems: [ControllerSessionItem] {
        sortSessionItems(sessionItems.filter { sessionActivity($0.session) != .needsYou })
    }

    private var sleepingItems: [ControllerSleepingItem] {
        controllers.flatMap { controller in
            filteredSleeping(controller).map { ControllerSleepingItem(controller: controller, session: $0) }
        }.sorted { left, right in
            if left.session.lastActiveAt != right.session.lastActiveAt {
                return left.session.lastActiveAt > right.session.lastActiveAt
            }
            return false
        }
    }

    private func sortSessionItems(_ items: [ControllerSessionItem]) -> [ControllerSessionItem] {
        items.sorted { sessionRecencyPrecedes($0.session, $1.session) }
    }

    var body: some View {
        NavigationStack {
            list
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if canCreateSession && (hasAnySessions || isMultiController) {
                        HStack {
                            Spacer()
                            Button(action: onNewSession) {
                                Image(systemName: "square.and.pencil")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.ccAccent)
                                    .frame(width: CCMetrics.controlCircle, height: CCMetrics.controlCircle)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
                            .contentShape(.rect)
                            .accessibilityLabel("New session")
                            .accessibilityIdentifier("new-session")
                            .padding(.trailing, 16)
                            .padding(.bottom, 12)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle("Sessions")
                .navigationSubtitle(subtitle ?? "")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            isSearchPresented = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Search sessions")
                        .accessibilityIdentifier("sessions-search")
                        Button(action: onSettings) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .searchable(
                    text: $searchText,
                    isPresented: $isSearchPresented,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search sessions"
                )
                .onChange(of: isSearchPresented) { _, presented in
                    if !presented { searchText = "" }
                }
                .refreshable { await onRefresh() }
        }
        .tint(.ccAccent)
        .background(.ccBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions-list")
        .task(id: allSessions.isEmpty) {
            guard !allSessions.isEmpty else { return }
            await onSessionsLoaded()
        }
    }

    @ViewBuilder
    private var list: some View {
        if !isMultiController && !hasAnySessions && controllers.allSatisfy({ if case .live = $0.connection { return true }; return false }) {
            ContentUnavailableView {
                Label("No sessions", systemImage: "terminal")
            } description: {
                Text("No Claude Code sessions are running on this Mac.")
            } actions: {
                if canCreateSession {
                    Button("New session", action: onNewSession)
                        .accessibilityIdentifier("empty-new-session")
                }
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
                statusRows
                if !needsYouItems.isEmpty {
                    Section("Needs you") {
                        ForEach(needsYouItems) { item in
                            sessionRow(item.session, controller: item.controller, showsControllerName: isMultiController)
                        }
                    }
                }
                if !recentItems.isEmpty {
                    Section("Recents") {
                        ForEach(recentItems) { item in
                            sessionRow(item.session, controller: item.controller, showsControllerName: isMultiController)
                        }
                    }
                }
                if !sleepingItems.isEmpty {
                    Section("Asleep") {
                        ForEach(sleepingItems) { item in
                            sleepingRow(item.session, controller: item.controller, showsControllerName: isMultiController)
                        }
                    }
                }
                if needsYouItems.isEmpty && recentItems.isEmpty && sleepingItems.isEmpty {
                    Section {
                        Text(query.isEmpty ? "No sessions" : "No matches")
                            .font(.subheadline)
                            .foregroundStyle(.ccTertiary)
                            .listRowBackground(Color.ccCard)
                            .accessibilityIdentifier("sessions-empty")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.ccBackground)
            .animation(.smooth, value: listAnimationKey)
        }
    }

    // MARK: Merged list layout

    @ViewBuilder
    private var statusRows: some View {
        ForEach(controllers.filter { if case .live = $0.connection { return false }; return true }) { controller in
            ControllerSectionHeader(
                controller: controller,
                onSignIn: { onSignIn(controller.id) },
                onRetry: { onRetry(controller.id) }
            )
            .listRowBackground(Color.ccCard)
            .listRowSeparatorTint(.ccSeparator)
        }
    }

    // MARK: Shared rows

    private func sleepingRow(_ session: SleepingSession, controller: SessionsListController, showsControllerName: Bool) -> some View {
        SleepingSessionRow(
            session: session,
            controllerName: showsControllerName ? controller.name : nil,
            isWaking: waking.contains(sleepingSessionKey(controllerID: controller.id, sessionID: session.id)),
            canWake: controller.capabilities.contains(.wake),
            onWake: { onWake(controller.id, session) },
            onCopyAttachCommand: { onCopyAttachCommand(session) }
        )
        .listRowBackground(Color.ccCard)
        .listRowSeparatorTint(.ccSeparator)
    }

    private func sessionRow(_ session: Session, controller: SessionsListController, showsControllerName: Bool) -> some View {
        SessionRow(
            session: session,
            approval: controller.approval(for: session),
            deciding: controller.deciding,
            frozen: controller.connection.isFrozen,
            dimmed: controller.connection.isFrozen,
            controllerName: showsControllerName ? controller.name : nil,
            canInterrupt: controller.capabilities.contains(.interrupt),
            canSetApprovalMode: controller.capabilities.contains(.mode),
            onOpen: { onOpen(controller.id, session) },
            onAllow: { onAllow(controller.id, $0) },
            onDeny: { onDeny(controller.id, $0) },
            onInterrupt: { onInterrupt(controller.id, session) },
            onSetApprovalMode: { mode in onSetApprovalMode(controller.id, session, mode) },
            onCopySessionID: { onCopySessionID(session) }
        )
        .opacity(isMultiController && controller.connection.isFrozen ? 0.6 : 1)
        .listRowBackground(Color.ccCard)
        .listRowSeparatorTint(.ccSeparator)
    }

    private var subtitle: String? {
        subtitleOverride ?? sessionsSubtitle(allSessions)
    }

    private var listAnimationKey: [String] {
        var keys: [String] = []
        for (position, item) in sortSessionItems(sessionItems).enumerated() {
            let parts = [
                "session",
                String(position),
                item.controller.id.rawValue,
                item.session.id ?? "",
                item.session.state?.rawValue ?? "",
                item.controller.approval(for: item.session)?.requestId ?? "",
            ]
            keys.append(parts.joined(separator: ":"))
        }
        for (position, item) in sleepingItems.enumerated() {
            let key = sleepingSessionKey(controllerID: item.controller.id, sessionID: item.session.id)
            keys.append("sleeping:\(position):\(key):\(waking.contains(key))")
        }
        for controller in controllers {
            keys.append("controller:\(controller.id.rawValue):\(controller.signInNeeded):\(controller.connection)")
        }
        return keys
    }
}

private struct ControllerSessionItem: Identifiable {
    let controller: SessionsListController
    let session: Session

    var id: String { "\(controller.id.rawValue)/\(session.id ?? "")" }
}

private struct ControllerSleepingItem: Identifiable {
    let controller: SessionsListController
    let session: SleepingSession

    var id: String { sleepingSessionKey(controllerID: controller.id, sessionID: session.id) }
}

/// A controller section header: name, status dot, and the status text.
private struct ControllerSectionHeader: View {
    let controller: SessionsListController
    let onSignIn: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(controller.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ccLabel)
                .textCase(nil)
                .lineLimit(1)
            Spacer(minLength: 4)
            if controller.signInNeeded {
                Button("Sign in needed", action: onSignIn)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.ccRed)
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityIdentifier("controller-sign-in-\(controller.id.rawValue)")
            } else if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .textCase(nil)
                    .lineLimit(1)
                Button("Retry", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityIdentifier("controller-retry-\(controller.id.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controller-section-\(controller.id.rawValue)")
        .accessibilityLabel(controller.name)
        .accessibilityValue(statusValue)
    }

    private var dotColor: Color {
        if controller.signInNeeded { return .ccRed }
        switch controller.connection {
        case .live: return .ccGreen
        case .reconnecting: return .ccAmber
        case .offline, .unreadable: return .ccTertiary
        }
    }

    private var statusText: String? {
        switch controller.connection {
        case .live: return nil
        case .reconnecting: return "Reconnecting…"
        case .offline(let updatedAt), .unreadable(let updatedAt):
            let elapsed = max(0, Date().timeIntervalSince(updatedAt) * 1000)
            return "updated \(formatListDuration(elapsed)) ago"
        }
    }

    private var statusValue: String {
        if controller.signInNeeded { return "signInNeeded" }
        switch controller.connection {
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .offline, .unreadable: return "offline"
        }
    }
}

private struct SessionRow: View {
    let session: Session
    let approval: Approval?
    let deciding: Set<String>
    let frozen: Bool
    let dimmed: Bool
    let controllerName: String?
    let canInterrupt: Bool
    let canSetApprovalMode: Bool
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
                    SessionText(session: session, approval: approval, controllerName: controllerName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(session.id.map { "session-\($0)" } ?? "session-")
            .accessibilityValue(activityStateLabel)

            if let approval, approval.questions == nil {
                ApprovalCard(
                    approval: approval,
                    style: .compact,
                    onOpen: onOpen,
                    onAllow: { onAllow(approval) },
                    onAllowSession: {},
                    onDeny: { onDeny(approval) },
                    controllerName: controllerName
                )
                .disabled(isDeciding(approval))
            }
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Open", action: onOpen)
            if canInterrupt, session.tmuxPane != nil {
                Button("Interrupt", role: .destructive, action: onInterrupt)
            }
            if canSetApprovalMode {
                Menu("Approvals mode") {
                    Button("Auto") { onSetApprovalMode(.auto) }
                    Button("Remote") { onSetApprovalMode(.remote) }
                    Button("Terminal") { onSetApprovalMode(.terminal) }
                }
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
    let controllerName: String?
    let isWaking: Bool
    let canWake: Bool
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
                    if let controllerName {
                        Label(controllerName, systemImage: "desktopcomputer")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                    }
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
        .disabled(!canWake)
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
    let controllerName: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let controllerName {
                Label(controllerName, systemImage: "desktopcomputer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(1)
            }
            Text(session.name ?? "Untitled session")
                .font(.headline)
                .foregroundStyle(.ccLabel)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            meta

            if !activity.isEmpty {
                Text(activity)
                    .font(.footnote.weight(isAsking || session.state == .needsYou ? .semibold : .regular))
                    .foregroundStyle(isAsking || session.state == .needsYou ? Color.ccAccent : Color.ccSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: some View {
        Group {
            if let stockadeMeta = stockadeSessionMeta(for: session) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(stockadeMeta)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("session-meta-\(session.id ?? "")")
                    Text("·")
                    SessionStateSegmentView(session: session)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if shouldWrapMeta {
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

    private var isAsking: Bool {
        approval?.questions != nil
    }

    private var shouldWrapMeta: Bool {
        (session.project ?? "").count > 10 || dynamicTypeSize >= .accessibility1
    }

    private var activity: String {
        if let approval, approval.questions != nil { return approvalCaption(approval) }
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
