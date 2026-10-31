import CCKit
import SwiftUI

/// One controller's slice of the sessions list.
struct SessionsListController: Identifiable {
    let id: ControllerID
    let name: String
    let kind: ControllerKind
    let connection: SessionsListView.Connection
    let signInNeeded: Bool
    let sessions: [Session]
    let sleeping: [SleepingSession]
    let approvals: [Approval]
    let capabilities: Set<ControllerCapability>

    init(
        id: ControllerID,
        name: String,
        kind: ControllerKind = .claudeCode,
        connection: SessionsListView.Connection = .live,
        signInNeeded: Bool = false,
        sessions: [Session],
        sleeping: [SleepingSession] = [],
        approvals: [Approval] = [],
        capabilities: Set<ControllerCapability> = ControllerCapability.all
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.connection = connection
        self.signInNeeded = signInNeeded
        self.sessions = sessions
        self.sleeping = sleeping
        self.approvals = approvals
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
    let isRegularSidebarHidden: Bool
    /// The session on screen beside or instead of this list, as a `sleepingSessionKey`.
    let openSessionKey: String?
    let onSessionsLoaded: () async -> Void
    let onOpen: (ControllerID, Session) -> Void
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
    let onArchive: (ControllerID, String, Bool) async -> Result<Void, ActionError>
    let onEnd: (ControllerID, String) async -> Result<Void, ActionError>
    let onActionError: (ActionError) -> Void

    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var archiveToast: ArchiveToast?
    @State private var archiveToastTask: Task<Void, Never>?
    @AppStorage("sessions.archived.collapsed") private var archivedCollapsed = true
    @AppStorage("sessions.pinned") private var pinnedStored = ""
    @AppStorage(SessionReadMarks.storageKey) private var readMarksStored = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var regularSearchFocused: Bool

    init(
        controllers: [SessionsListController],
        waking: Set<String> = [],
        subtitleOverride: String? = nil,
        notice: String? = nil,
        canCreateSession: Bool = true,
        isRegularSidebarHidden: Bool = false,
        openSessionKey: String? = nil,
        onSessionsLoaded: @escaping () async -> Void = {},
        onOpen: @escaping (ControllerID, Session) -> Void = { _, _ in },
        onRetry: @escaping (ControllerID) -> Void = { _ in },
        onSignIn: @escaping (ControllerID) -> Void = { _ in },
        onSettings: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {},
        onInterrupt: @escaping (ControllerID, Session) -> Void = { _, _ in },
        onSetApprovalMode: @escaping (ControllerID, Session, ApprovalMode) -> Void = { _, _, _ in },
        onCopySessionID: @escaping (Session) -> Void = { _ in },
        onNewSession: @escaping () -> Void = {},
        onWake: @escaping (ControllerID, SleepingSession) -> Void = { _, _ in },
        onCopyAttachCommand: @escaping (SleepingSession) -> Void = { _ in },
        onArchive: @escaping (ControllerID, String, Bool) async -> Result<Void, ActionError> = { _, _, _ in .success(()) },
        onEnd: @escaping (ControllerID, String) async -> Result<Void, ActionError> = { _, _ in .success(()) },
        onActionError: @escaping (ActionError) -> Void = { _ in }
    ) {
        self.controllers = controllers
        self.waking = waking
        self.subtitleOverride = subtitleOverride
        self.notice = notice
        self.canCreateSession = canCreateSession
        self.isRegularSidebarHidden = isRegularSidebarHidden
        self.openSessionKey = openSessionKey
        self.onSessionsLoaded = onSessionsLoaded
        self.onOpen = onOpen
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
        self.onArchive = onArchive
        self.onEnd = onEnd
        self.onActionError = onActionError
    }

    /// The single-controller form, used by the mocks.
    init(
        sessions: [Session],
        sleeping: [SleepingSession] = [],
        approvals: [Approval] = [],
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
                    approvals: approvals
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

    private var pins: PinnedSessions { PinnedSessions(stored: pinnedStored) }
    private var readMarks: SessionReadMarks { SessionReadMarks(stored: readMarksStored) }

    /// Pinned sessions stay in the order they were pinned, so they don't move as activity changes.
    private var pinnedItems: [RecentSessionItem] {
        let pins = self.pins
        return unarchivedItems
            .filter { pins.contains($0.pinKey) }
            .sorted { (pins.position(of: $0.pinKey) ?? 0) < (pins.position(of: $1.pinKey) ?? 0) }
    }

    private var recentItems: [RecentSessionItem] {
        let pins = self.pins
        return unarchivedItems
            .filter { !pins.contains($0.pinKey) }
            .sorted(by: recentSessionPrecedes)
    }

    private var unarchivedItems: [RecentSessionItem] {
        let live = sessionItems
            .filter { $0.session.archivedAt == nil || sessionActivity($0.session) == .needsYou }
            .map(RecentSessionItem.live)
        let sleeping = controllers.flatMap { controller in
            filteredSleeping(controller)
                .filter { $0.archivedAt == nil }
                .map { RecentSessionItem.sleeping(ControllerSleepingItem(controller: controller, session: $0)) }
        }
        return live + sleeping
    }

    private func setPinned(_ pinned: Bool, key: String) {
        var pins = self.pins
        pins.setPinned(pinned, key: key)
        withAnimation(reduceMotion ? nil : .smooth) { pinnedStored = pins.stored }
    }

    private func recentSessionPrecedes(_ left: RecentSessionItem, _ right: RecentSessionItem) -> Bool {
        let leftDate = left.lastUserMessageDate
        let rightDate = right.lastUserMessageDate
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        switch (left, right) {
        case let (.live(left), .live(right)):
            return sessionRecencyPrecedes(left.session, right.session)
        case let (.sleeping(left), .sleeping(right)):
            return left.session.lastActiveAt > right.session.lastActiveAt
        default:
            return left.id < right.id
        }
    }

    private var archivedSessionItems: [ControllerSessionItem] {
        sortSessionItems(sessionItems.filter { $0.session.archivedAt != nil && sessionActivity($0.session) != .needsYou })
    }

    private var archivedSleepingItems: [ControllerSleepingItem] {
        controllers.flatMap { controller in
            filteredSleeping(controller).filter { $0.archivedAt != nil }.map { ControllerSleepingItem(controller: controller, session: $0) }
        }.sorted { left, right in
            left.session.lastActiveAt > right.session.lastActiveAt
        }
    }

    private var archivedCount: Int { archivedSessionItems.count + archivedSleepingItems.count }

    private func sortSessionItems(_ items: [ControllerSessionItem]) -> [ControllerSessionItem] {
        items.sorted { sessionRecencyPrecedes($0.session, $1.session) }
    }

    @ViewBuilder
    private var bottomInset: some View {
        VStack(spacing: 8) {
            archiveToastOverlay
            // The compact layout puts New session in the toolbar next to search and settings.
            if canCreateSession && horizontalSizeClass == .regular {
                newSessionButton
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var newSessionButton: some View {
        HStack {
            Spacer()
            Button(action: onNewSession) {
                newSessionButtonLabel
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

    private var newSessionButtonLabel: some View {
        Image(systemName: "square.and.pencil")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(.ccAccent, in: .circle)
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.30 : 0.12),
                radius: 8,
                y: 2
            )
    }

    @ViewBuilder
    private var archiveToastOverlay: some View {
        if let archiveToast {
            ArchiveToastView(toast: archiveToast, reduceMotion: reduceMotion) {
                archive(archiveToast.controllerID, archiveToast.sessionID, false, name: archiveToast.name)
            }
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        NavigationStack {
            if horizontalSizeClass == .regular {
                list
                    .safeAreaInset(edge: .top, spacing: 0) {
                        regularHeader
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomInset
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .refreshable { await onRefresh() }
            } else {
                list
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomInset
                    }
                    .navigationTitle("Sessions")
                    .navigationBarTitleDisplayMode(.large)
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
                            if canCreateSession && (hasAnySessions || isMultiController) {
                                Button(action: onNewSession) {
                                    Image(systemName: "square.and.pencil")
                                }
                                .accessibilityLabel("New session")
                                .accessibilityIdentifier("new-session")
                            }
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
        }
        .tint(.ccAccent)
        .background(.ccBackground)
        .toolbarBackground(.ccBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityElement(children: isRegularSidebarHidden ? .ignore : .contain)
        .accessibilityIdentifier(isRegularSidebarHidden ? "sessions-list-hidden" : "sessions-list")
        .accessibilityHidden(isRegularSidebarHidden)
        .task(id: allSessions.isEmpty) {
            guard !allSessions.isEmpty else { return }
            await onSessionsLoaded()
        }
    }

    private var regularHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: RegularHeaderMetrics.toggleSize, height: RegularHeaderMetrics.toggleSize)
                    .accessibilityHidden(true)
                    .padding(.trailing, RegularHeaderMetrics.controlSpacing)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sessions")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                        .accessibilityLabel("Sessions")
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Settings")
            }
            .frame(height: RegularHeaderMetrics.toggleSize)
            .padding(.horizontal, RegularHeaderMetrics.horizontalPadding)
            regularSearchField
        }
        .padding(.top, RegularHeaderMetrics.topPadding)
        .background(.ccBackground)
    }

    private var regularSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.ccSecondary)
            TextField("Search sessions", text: $searchText)
                .focused($regularSearchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("sessions-search-field")
                .onSubmit { regularSearchFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.ccSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(height: 36)
        .padding(.horizontal, 12)
        .background(.ccLabel.opacity(0.06), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
            sessionList
                .listStyle(.plain)
        }
    }

    private var sessionList: some View {
        List {
            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                        .modifier(SessionsListRowBackground())
                }
            }
            statusRows
            if !pinnedItems.isEmpty {
                Section {
                    ForEach(pinnedItems) { item in
                        recentRow(item)
                    }
                } header: {
                    Text("Pinned")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccSecondary)
                        .textCase(nil)
                        .padding(.top, 8)
                        .accessibilityIdentifier("sessions-pinned-header")
                }
            }
            if !recentItems.isEmpty {
                Section {
                    ForEach(recentItems) { item in
                        recentRow(item)
                    }
                } header: {
                    Text("Recents")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccSecondary)
                        .textCase(nil)
                        .padding(.top, 8)
                }
            }
            if archivedCount > 0 {
                Section {
                    if !archivedCollapsed {
                        ForEach(archivedSessionItems) { item in
                            sessionRow(item.session, controller: item.controller, showsControllerName: isMultiController, isArchived: true)
                        }
                        ForEach(archivedSleepingItems) { item in
                            sleepingRow(item.session, controller: item.controller, showsControllerName: isMultiController, isArchived: true)
                        }
                    }
                } header: {
                    ArchivedSectionHeader(count: archivedCount, isCollapsed: archivedCollapsed) {
                        withAnimation(reduceMotion ? nil : .smooth) { archivedCollapsed.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccSecondary)
                    .textCase(nil)
                    .padding(.top, 8)
                }
            }
            if pinnedItems.isEmpty && recentItems.isEmpty && archivedCount == 0 {
                Section {
                    Text(query.isEmpty ? "No sessions" : "No matches")
                        .font(.subheadline)
                        .foregroundStyle(.ccTertiary)
                        .modifier(SessionsListRowBackground())
                        .accessibilityIdentifier("sessions-empty")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(.ccBackground)
        .listRowSeparator(.hidden)
        .animation(.smooth, value: listAnimationKey)
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
            .modifier(SessionsListRowBackground())
            .listRowSeparator(.hidden)
        }
    }

    // MARK: Shared rows

    @ViewBuilder
    private func recentRow(_ item: RecentSessionItem) -> some View {
        switch item {
        case .live(let item):
            sessionRow(item.session, controller: item.controller, showsControllerName: isMultiController, isArchived: false)
        case .sleeping(let item):
            sleepingRow(item.session, controller: item.controller, showsControllerName: isMultiController, isArchived: false)
        }
    }

    private func sleepingRow(_ session: SleepingSession, controller: SessionsListController, showsControllerName: Bool, isArchived: Bool) -> some View {
        SleepingSessionRow(
            session: session,
            controllerName: showsControllerName ? controller.name : nil,
            readStatus: readMarks.status(
                for: session,
                key: sleepingSessionKey(controllerID: controller.id, sessionID: session.id),
                isOpen: openSessionKey == sleepingSessionKey(controllerID: controller.id, sessionID: session.id)
            ),
            isWaking: waking.contains(sleepingSessionKey(controllerID: controller.id, sessionID: session.id)),
            canWake: controller.capabilities.contains(.wake),
            canArchive: controller.capabilities.contains(.archive),
            isArchived: isArchived,
            pin: isArchived ? nil : pinToggle(sleepingSessionKey(controllerID: controller.id, sessionID: session.id)),
            onWake: { onWake(controller.id, session) },
            onCopyAttachCommand: { onCopyAttachCommand(session) },
            onArchive: { archive(controller.id, session.id, !isArchived, name: session.name ?? session.project) }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .modifier(SessionsListRowBackground())
        .listRowSeparator(.hidden)
    }

    private func sessionRow(_ session: Session, controller: SessionsListController, showsControllerName: Bool, isArchived: Bool) -> some View {
        let hasPendingApproval = controller.approval(for: session) != nil
        let needsYou = sessionActivity(session) == .needsYou
        let canManageSession = !needsYou && !hasPendingApproval
        let sessionKey = session.id.map { sleepingSessionKey(controllerID: controller.id, sessionID: $0) } ?? ""
        return SessionRow(
            session: session,
            readStatus: readMarks.status(for: session, key: sessionKey, isOpen: openSessionKey == sessionKey),
            frozen: controller.connection.isFrozen,
            dimmed: controller.connection.isFrozen,
            controllerName: showsControllerName ? controller.name : nil,
            controllerLabel: controller.name,
            controllerKind: controller.kind,
            canInterrupt: controller.capabilities.contains(.interrupt),
            canSetApprovalMode: controller.capabilities.contains(.mode),
            canArchive: canManageSession && controller.capabilities.contains(.archive),
            canEnd: canManageSession && controller.capabilities.contains(.close) && session.closable,
            isArchived: isArchived,
            pin: isArchived ? nil : session.id.map { pinToggle(sleepingSessionKey(controllerID: controller.id, sessionID: $0)) },
            onOpen: { onOpen(controller.id, session) },
            onInterrupt: { onInterrupt(controller.id, session) },
            onSetApprovalMode: { mode in onSetApprovalMode(controller.id, session, mode) },
            onCopySessionID: { onCopySessionID(session) },
            onArchive: { archive(controller.id, session.id, !isArchived, name: session.name ?? "Untitled session") },
            onEnd: { end(controller.id, session.id) }
        )
        .opacity(isMultiController && controller.connection.isFrozen ? 0.6 : 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .modifier(SessionsListRowBackground())
        .listRowSeparator(.hidden)
    }

    private func pinToggle(_ key: String) -> PinToggle {
        let isPinned = pins.contains(key)
        return PinToggle(key: key, isPinned: isPinned) { setPinned(!isPinned, key: key) }
    }

    private func archive(_ controllerID: ControllerID, _ sessionID: String?, _ archived: Bool, name: String) {
        guard let sessionID else { return }
        Task { @MainActor in
            switch await onArchive(controllerID, sessionID, archived) {
            case .success:
                if archived { showArchiveToast(name: name, controllerID: controllerID, sessionID: sessionID) }
                else { archiveToast = nil }
            case .failure(let error): onActionError(error)
            }
        }
    }

    private func end(_ controllerID: ControllerID, _ sessionID: String?) {
        guard let sessionID else { return }
        Task { @MainActor in
            if case .failure(let error) = await onEnd(controllerID, sessionID) { onActionError(error) }
        }
    }

    private func showArchiveToast(name: String, controllerID: ControllerID, sessionID: String) {
        archiveToastTask?.cancel()
        archiveToast = ArchiveToast(name: name, controllerID: controllerID, sessionID: sessionID)
        archiveToastTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled else { return }
            archiveToast = nil
        }
    }

    private var subtitle: String? {
        subtitleOverride ?? sessionsSubtitle(allSessions)
    }

    private var listAnimationKey: [String] {
        var keys = pinnedItems.map { "pinned:\($0.id)" }
        for (position, item) in recentItems.enumerated() {
            switch item {
            case .live(let item):
                let parts = [
                    "session",
                    String(position),
                    item.controller.id.rawValue,
                    item.session.id ?? "",
                    item.session.state?.rawValue ?? "",
                    item.controller.approval(for: item.session)?.requestId ?? "",
                ]
                keys.append(parts.joined(separator: ":"))
            case .sleeping(let item):
                let key = sleepingSessionKey(controllerID: item.controller.id, sessionID: item.session.id)
                keys.append("sleeping:\(position):\(key):\(waking.contains(key))")
            }
        }
        for item in archivedSessionItems {
            keys.append("archived:\(item.controller.id.rawValue):\(item.session.id ?? "")")
        }
        for item in archivedSleepingItems {
            keys.append("archived-sleeping:\(item.controller.id.rawValue):\(item.session.id)")
        }
        keys.append("archived-collapsed:\(archivedCollapsed)")
        for controller in controllers {
            keys.append("controller:\(controller.id.rawValue):\(controller.signInNeeded):\(controller.connection)")
        }
        return keys
    }
}

private struct ArchiveToast: Equatable {
    let name: String
    let controllerID: ControllerID
    let sessionID: String
}

private struct ArchiveToastView: View {
    let toast: ArchiveToast
    let reduceMotion: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Archived \u{201c}\(toast.name)\u{201d}")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.ccLabel)
                .lineLimit(1)
            Button("Undo", action: onUndo)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("archive-undo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: .capsule)
        .shadow(radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive-toast")
    }
}

private struct ArchivedSectionHeader: View {
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text("Archived · \(count)")
                Spacer()
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Archived · \(count)")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("archived-section-header")
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

private enum RecentSessionItem: Identifiable {
    case live(ControllerSessionItem)
    case sleeping(ControllerSleepingItem)

    var id: String {
        switch self {
        case .live(let item): "live:\(item.id)"
        case .sleeping(let item): "sleeping:\(item.id)"
        }
    }

    /// "controller/session", the same for a session asleep or awake.
    var pinKey: String {
        switch self {
        case .live(let item): item.session.id == nil ? "" : item.id
        case .sleeping(let item): item.id
        }
    }

    /// When you last wrote to the session, or the nearest thing the controller knows when it can't say.
    var lastUserMessageDate: Date {
        switch self {
        case .live(let item):
            // An inexact time is the session's last activity, which moves when a turn ends, so it isn't used
            // unless there's nothing else.
            if item.session.lastUserMessageAtExact == false, let startedAt = item.session.startedAt {
                return startedAt
            }
            return item.session.lastUserMessageAt
                ?? max(item.session.idleSince ?? .distantPast, item.session.startedAt ?? .distantPast)
        case .sleeping(let item):
            return item.session.lastUserMessageAt ?? item.session.lastActiveAt
        }
    }
}

/// A row's pin state and the action that flips it; rows that can't be pinned get none.
private struct PinToggle {
    let key: String
    let isPinned: Bool
    let toggle: () -> Void

    var title: String { isPinned ? "Unpin" : "Pin" }
    var systemImage: String { isPinned ? "pin.slash" : "pin" }
    var identifier: String { "session-\(isPinned ? "unpin" : "pin")-\(key.split(separator: "/", maxSplits: 1).last ?? "")" }
}

private struct PinSwipeAction: ViewModifier {
    let pin: PinToggle?

    func body(content: Content) -> some View {
        content.swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let pin {
                Button(action: pin.toggle) {
                    Label(pin.title, systemImage: pin.systemImage)
                }
                .tint(.orange)
                .accessibilityLabel("\(pin.title) session")
                .accessibilityIdentifier(pin.identifier)
            }
        }
    }
}

private struct SessionsListRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowBackground(Color.ccBackground)
    }
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let session: Session
    let readStatus: SessionReadStatus
    let frozen: Bool
    let dimmed: Bool
    let controllerName: String?
    let controllerLabel: String
    let controllerKind: ControllerKind
    let canInterrupt: Bool
    let canSetApprovalMode: Bool
    let canArchive: Bool
    let canEnd: Bool
    let isArchived: Bool
    let pin: PinToggle?
    let onOpen: () -> Void
    let onInterrupt: () -> Void
    let onSetApprovalMode: (ApprovalMode) -> Void
    let onCopySessionID: () -> Void
    let onArchive: () -> Void
    let onEnd: () -> Void
    @State private var endConfirmationPresented = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                SessionStatusIndicator(
                    status: readStatus,
                    identifier: "session-status-\(session.id ?? "")",
                    frozen: frozen,
                    dimmed: dimmed
                )
                SessionText(session: session, controllerName: controllerName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(session.id.map { "session-\($0)" } ?? "session-")
        .accessibilityValue(readStatus.rawValue)
        .padding(.vertical, 10)
        .modifier(PinSwipeAction(pin: pin))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // In large mode a left swipe closes the sidebar; these stay in the context menu.
            if canArchive, horizontalSizeClass != .regular {
                Button(action: onArchive) {
                    Label(isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                }
                .tint(.gray)
                .accessibilityLabel(isArchived ? "Unarchive session" : "Archive session")
                .accessibilityIdentifier("session-\(isArchived ? "unarchive" : "archive")-\(session.id ?? "")")
            }
            if canEnd, horizontalSizeClass != .regular {
                Button { endConfirmationPresented = true } label: {
                    Label("End session", systemImage: "stop.circle")
                }
                .tint(.red)
                .accessibilityLabel("End session")
                .accessibilityIdentifier("session-end-\(session.id ?? "")")
            }
        }
        .contextMenu {
            Button("Open", action: onOpen)
            if let pin {
                Button(pin.title, systemImage: pin.systemImage, action: pin.toggle)
                    .accessibilityIdentifier(pin.identifier)
            }
            if canArchive {
                Button(isArchived ? "Unarchive" : "Archive", action: onArchive)
                    .accessibilityIdentifier("session-\(isArchived ? "unarchive" : "archive")-\(session.id ?? "")")
            }
            if canEnd {
                Button("End session…", role: .destructive) { endConfirmationPresented = true }
                    .accessibilityIdentifier("session-end-\(session.id ?? "")")
            }
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
        .confirmationDialog("End this session?", isPresented: $endConfirmationPresented, titleVisibility: .visible) {
            Button("End session", role: .destructive, action: onEnd)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(endMessage)
        }
    }

    private var endMessage: String {
        if controllerKind == .stockade {
            return "It closes on \(controllerLabel). Your next message reopens it."
        }
        if session.background != nil {
            return "It stops on your Mac. The conversation stays in Recents, and tapping it wakes it."
        }
        return "It stops. The conversation stays in Recents, and tapping it wakes it."
    }
}

private struct SleepingSessionRow: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let session: SleepingSession
    let controllerName: String?
    let readStatus: SessionReadStatus
    let isWaking: Bool
    let canWake: Bool
    let canArchive: Bool
    let isArchived: Bool
    let pin: PinToggle?
    let onWake: () -> Void
    let onCopyAttachCommand: () -> Void
    let onArchive: () -> Void

    var body: some View {
        Button(action: onWake) {
            HStack(alignment: .center, spacing: 12) {
                if isWaking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else {
                    SessionStatusIndicator(
                        status: readStatus,
                        identifier: "session-status-\(session.id)",
                        frozen: false,
                        dimmed: false
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.body)
                        .foregroundStyle(.ccLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("sleeping-session-title-\(session.id)")
                    Text(projectLine)
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canWake)
        .accessibilityIdentifier("sleeping-session-\(session.id)")
        .accessibilityValue(isWaking ? "Waking" : readStatus.rawValue)
        .modifier(PinSwipeAction(pin: pin))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // In large mode a left swipe closes the sidebar; these stay in the context menu.
            if canArchive, horizontalSizeClass != .regular {
                Button(action: onArchive) {
                    Label(isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                }
                .tint(.gray)
                .accessibilityLabel(isArchived ? "Unarchive session" : "Archive session")
                .accessibilityIdentifier("session-\(isArchived ? "unarchive" : "archive")-\(session.id)")
            }
        }
        .contextMenu {
            if let pin {
                Button(pin.title, systemImage: pin.systemImage, action: pin.toggle)
                    .accessibilityIdentifier(pin.identifier)
            }
            if canArchive {
                Button(isArchived ? "Unarchive" : "Archive", action: onArchive)
                    .accessibilityIdentifier("session-\(isArchived ? "unarchive" : "archive")-\(session.id)")
            }
            Button("Copy attach command", action: onCopyAttachCommand)
        }
        .padding(.vertical, 10)
    }

    private var displayName: String {
        let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? session.project : name
    }

    private var projectLine: String {
        controllerName.map { "\(session.project) · \($0)" } ?? session.project
    }
}

private struct SessionStatusIndicator: View {
    let status: SessionReadStatus
    let identifier: String
    let frozen: Bool
    let dimmed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ccFreezeLiveIndicators) private var freezeLiveIndicators

    var body: some View {
        statusView
            .frame(width: 22, height: 22)
            .animation(freezeLiveIndicators ? nil : .easeInOut(duration: 0.2), value: status)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .working:
            SpinnerGlyph(active: true, frozen: frozen, dimmed: dimmed)
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier(identifier)
                .transition(statusTransition)
        case .unread:
            Circle()
                .fill(.ccAccent)
                .frame(width: 8, height: 8)
                .accessibilityIdentifier(identifier)
                .transition(statusTransition)
        case .read:
            Image(systemName: "bubble.left")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.ccTertiary)
                .accessibilityIdentifier(identifier)
                .transition(statusTransition)
        }
    }

    private var statusTransition: AnyTransition {
        reduceMotion || freezeLiveIndicators ? .opacity : .opacity.combined(with: .scale(scale: 0.8))
    }
}

private struct SessionText: View {
    let session: Session
    let controllerName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.name ?? "Untitled session")
                .font(.body)
                .foregroundStyle(.ccLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("session-title-\(session.id ?? "")")

            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.ccSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("session-agent-\(session.id ?? "")")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let agent = session.agent?.name ?? session.agent?.id ?? session.project ?? "unknown project"
        return controllerName.map { "\(agent) · \($0)" } ?? agent
    }

}
