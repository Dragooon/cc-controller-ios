import CCKit
import SwiftUI
import UIKit

struct MainSplitView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var regularSidebarProgress: CGFloat = 1
    /// Whether the detail has made room for the open sidebar. It stays false while the sidebar moves,
    /// so the detail slides at one width and lays out once instead of on every frame.
    @State private var regularDetailFitsBesideSidebar = true
    @State private var isRegularInspectorOpen = false
    /// Whether the detail column still has room for the inspector with the sidebar open.
    @State private var regularInspectorFitsBesideSidebar = true
#if DEBUG
    @State private var regularSwipeDiagnostic = ""
#endif
    @State private var regularSidebarDragStartProgress: CGFloat?
    @AppStorage(SessionReadMarks.storageKey) private var readMarksStored = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var newSessionControllerID: ControllerID = .mac
    @State private var newSessionPrompt = ""
    /// Keys from `sleepingSessionKey(controllerID:sessionID:)`.
    @State private var wakingSessionIDs: Set<String> = []
    @State private var wakeFailures: [String: String] = [:]
    @State private var sessionNotice: String?

    init(model: AppModel) {
        self.model = model
        let hasSelectedSession = model.selectedSession != nil
        _columnVisibility = State(initialValue: .all)
        _preferredCompactColumn = State(initialValue: hasSelectedSession ? .detail : .sidebar)
    }

    var body: some View {
        ZStack(alignment: .top) {
            splitView()
#if DEBUG
            Text(horizontalSizeClass == .regular ? "regular" : "compact")
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("horizontal-size-class")
                .accessibilityValue(columnVisibility == .detailOnly ? "detailOnly" : "not-detailOnly")
            Text(" ")
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("controller-connections")
                .accessibilityValue(model.connections.map { "\($0.config.id.rawValue)=\(connectionStateLabel($0.store.connection))" }.joined(separator: ","))
#endif
            if let warning = model.relayIdentityWarning {
                Button {
                    model.isRelayWarningPresented = true
                } label: {
                    Label("\(warning.label) presented a different Mac identity.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ccAmber)
                        .foregroundStyle(.black)
                }
                .accessibilityIdentifier("relay-identity-warning")
            }
        }
        .task { startReadMarksIfNeeded() }
        .onChange(of: openSessionReadTrigger, initial: true) { _, _ in markOpenSessionRead() }
        .alert(
            "Mac identity changed",
            isPresented: $model.isRelayWarningPresented
        ) {
            Button("OK", role: .cancel) { model.isRelayWarningPresented = false }
        } message: {
            Text("\(model.relayIdentityWarning?.label ?? "This endpoint") presented a different Mac identity. Code is using the matching endpoint.")
        }
        .alert(
            actionErrorTitle,

            isPresented: Binding(
                get: { model.actionError != nil },
                set: { isPresented in
                    if !isPresented { model.actionError = nil }
                }
            )
        ) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError?.userMessage ?? "The action could not be completed.")
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(
                address: model.connectionAddress,
                relayMode: model.relayMode,
                relayAddresses: model.relayAddressesDraft,
                relayPin: model.relayPinGrouped,
                connectedVia: model.relayMode ? model.connectionLabel : nil,
                latency: model.settings.latency,
                connectionTest: model.settings.connectionTest,
                thisDevice: model.settings.thisDevice,
                pairedDevices: model.settings.pairedDevices,
                appVersion: model.appVersion,
                daemon: model.primaryStore.daemon,
                apiVersion: model.primaryStore.apiVersion,
                isUnpairing: model.isUnpairing,
                lockAfter: SettingsLockInterval(model.lockPolicy.interval),
                onDone: { model.isSettingsPresented = false },
                onTestConnection: { Task { await model.settings.testConnection() } },
                onLockNow: model.lockNow,
                onUnpair: { Task { await model.unpair() } },
                onLockInterval: { model.setLockInterval($0.lockInterval) },
                onRetryDevices: { Task { await model.settings.loadPairedDevices() } },
                onSaveRelayAddresses: model.setRelayAddresses,
                onResetRelayAddresses: model.resetRelayAddresses,
                controllers: model.controllerRows,
                controllerDetail: { id, onRemoved in
                    AnyView(ControllerDetailView(model: model, controllerID: id, onRemoved: onRemoved))
                },
                addController: { onDone in
                    AnyView(AddControllerView(appModel: model, onDone: onDone))
                }
            )
            .onAppear { model.settingsDidAppear() }
            .onDisappear { model.settingsDidDisappear() }
        }
        .onAppear {
            synchronizeColumnVisibility()
            consumeResumeNewSessionRequest()
        }
        .onChange(of: model.shouldResumeNewSession) { _, requested in
            guard requested else { return }
            consumeResumeNewSessionRequest()
        }
        .onChange(of: model.selectedSession) { _, _ in
            synchronizeColumnVisibility()
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            if newSizeClass == .regular {
                columnVisibility = .all
                preferredCompactColumn = .sidebar
                regularSidebarProgress = 1
                regularDetailFitsBesideSidebar = true
            } else {
                synchronizeColumnVisibility()
            }
        }
    }

    @ViewBuilder
    private func splitView() -> some View {
        if horizontalSizeClass == .regular {
            regularSplitView()
        } else {
            splitViewContent()
                .navigationSplitViewStyle(.prominentDetail)
                .tint(.ccAccent)
                .background(.ccBackground)
        }
    }

    private func splitViewContent() -> some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sessionsList()
        } detail: {
            detailView()
        }
    }

    private func regularSplitView() -> some View {
        GeometryReader { outerProxy in
            let proxySize = regularLayoutSize(available: outerProxy.size)
            let sidebarWidth = min(360, max(300, proxySize.width * 0.3))
            regularSplitContent(
                width: proxySize.width,
                height: proxySize.height,
                sidebarWidth: sidebarWidth
            )
            .frame(width: proxySize.width, alignment: .leading)
            .onChange(of: proxySize.width - sidebarWidth, initial: true) { _, remainingWidth in
                regularInspectorFitsBesideSidebar = remainingWidth >= RegularHeaderMetrics.minimumDetailWidthWithInspector
            }
#if DEBUG
            .overlay {
                Text(" ")
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityIdentifier("regular-layout-metrics")
                    .accessibilityValue("width=\(proxySize.width),sidebar=\(sidebarWidth),swipe=\(regularSwipeDiagnostic)")
            }
#endif
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }

    /// The open Duo simulator stays in landscape, so tests can ask for the width the phone has in portrait.
    private func regularLayoutSize(available: CGSize) -> CGSize {
#if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-CCRegularWidth"),
           ProcessInfo.processInfo.arguments.count > index + 1,
           let width = Double(ProcessInfo.processInfo.arguments[index + 1]) {
            return CGSize(width: min(available.width, width), height: available.height)
        }
#endif
        return available
    }

    private func regularSplitContent(
        width: CGFloat,
        height: CGFloat,
        sidebarWidth: CGFloat
    ) -> some View {
        let isClosingSidebar = regularSidebarDragStartProgress.map { $0 > 0 } ?? false
        return ZStack(alignment: .leading) {
            regularDetailColumn(width: width, sidebarWidth: sidebarWidth)
            regularSidebarColumn(sidebarWidth: sidebarWidth)
            regularSidebarPanCapture(
                sidebarWidth: sidebarWidth,
                height: height,
                isClosingSidebar: isClosingSidebar
            )
        }
        .overlay {
            if regularSidebarDragStartProgress != nil {
                Color.black
                    .opacity(0.18 * regularSidebarProgress)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            regularSidebarControls()
        }
    }

    private func regularDetailColumn(width: CGFloat, sidebarWidth: CGFloat) -> some View {
        let shift = sidebarWidth * regularSidebarProgress
        return regularDetailNavigation()
            .frame(width: max(0, regularDetailFitsBesideSidebar ? width - sidebarWidth : width))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(x: shift)
    }

    private func regularDetailNavigation() -> some View {
        NavigationStack {
            regularDetailContent()
        }
        .environment(\.regularHeaderLeadingInset, regularDetailHeaderLeadingInset)
    }

    /// The system bar shares the status bar's row on some devices and loses most of its width to it,
    /// so each large-mode screen draws its own header under the status bar.
    private func regularDetailContent() -> some View {
        detailView()
            .toolbar(.hidden, for: .navigationBar)
    }

    /// Room for the fixed sidebar controls, which only sit over the detail while the sidebar is closed.
    private var regularDetailHeaderLeadingInset: CGFloat {
        guard columnVisibility == .detailOnly else { return 0 }
        return RegularHeaderMetrics.toggleSize + RegularHeaderMetrics.controlSpacing
    }

    private func regularSidebarColumn(sidebarWidth: CGFloat) -> some View {
        sessionsList(isRegularSidebarHidden: regularSidebarProgress <= 0.001)
            .accessibilityHidden(regularSidebarProgress <= 0.001)
            .frame(width: sidebarWidth)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(width: 1 / displayScale)
                    .frame(maxHeight: .infinity)
            }
            .modifier(SidebarRevealModifier(progress: regularSidebarProgress, sidebarWidth: sidebarWidth))
            .zIndex(1)
#if DEBUG
            .overlay { LayoutFrameProbe(identifier: "sessions-list-frame") }
#endif
            .accessibilityHidden(regularSidebarProgress <= 0.001)
    }

    private func regularSidebarPanCapture(
        sidebarWidth: CGFloat,
        height: CGFloat,
        isClosingSidebar: Bool
    ) -> some View {
        SidebarPanCapture(
            sidebarProgress: regularSidebarProgress,
            opensFromAnywhere: !isRegularInspectorOpen,
            onSwipeDiagnostic: { diagnostic in
#if DEBUG
                regularSwipeDiagnostic = diagnostic
#endif
            },
            onChanged: { translationX in
                sidebarDragChanged(translationX: translationX, sidebarWidth: sidebarWidth)
            },
            onEnded: { translationX, velocityX in
                sidebarDragEnded(
                    translationX: translationX,
                    velocityX: velocityX,
                    sidebarWidth: sidebarWidth
                )
            }
        )
        .frame(
            width: regularSidebarProgress > 0 || isClosingSidebar ? 80 : 32,
            height: height
        )
        .accessibilityIdentifier(
            regularSidebarProgress > 0 || isClosingSidebar ? "sidebar-close-strip" : "sidebar-edge-strip"
        )
        .zIndex(2)
    }

    @ViewBuilder
    private func detailView() -> some View {
        if model.isNewSessionPresented {
            let store = model.connection(for: newSessionControllerID)?.store ?? model.primaryStore
            let controllerID = newSessionControllerID
            NewSessionView(
                store: store,
                controllerChoices: newSessionChoices,
                selectedControllerID: $newSessionControllerID,
                promptBinding: $newSessionPrompt,
                isEmbedded: true
            ) { id, appeared in
                openSession(controllerID, id)
                if !appeared {
                    sessionNotice = "Session started; it will appear shortly."
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        sessionNotice = nil
                    }
                }
            }
#if DEBUG
            .overlay { LayoutFrameProbe(identifier: "session-detail-frame") }
#endif
        } else if let selectedSession = model.selectedSession,
                  let selectedConnection = model.connection(for: selectedSession.controllerID) {
            SessionScreen(
                sessionID: selectedSession.sessionID,
                store: selectedConnection.store,
                model: model,
                approvalsElsewhereCount: approvalsElsewhereCount,
                isWaking: wakingSessionIDs.contains(sleepingSessionKey(controllerID: selectedSession.controllerID, sessionID: selectedSession.sessionID))
                    && selectedConnection.store.sessions[selectedSession.sessionID]?.live != true,
                wakeError: selectedConnection.store.sessions[selectedSession.sessionID]?.live == true
                    ? nil
                    : wakeFailures[sleepingSessionKey(controllerID: selectedSession.controllerID, sessionID: selectedSession.sessionID)],
                onRetryWake: {
                    guard let sleeping = selectedConnection.store.sleeping.first(where: { $0.id == selectedSession.sessionID }) else { return }
                    wakeSession(selectedSession.controllerID, sleeping)
                },
                onShowApprovalsElsewhere: {
                    if horizontalSizeClass == .regular {
                        showSidebar()
                    } else {
                        columnVisibility = .all
                    }
                },
                sidebarCrowdsInspector: !regularInspectorFitsBesideSidebar && columnVisibility == .all,
                onRegularInspectorChange: { isOpen in
                    isRegularInspectorOpen = isOpen
                    if isOpen, !regularInspectorFitsBesideSidebar, columnVisibility == .all {
                        toggleSidebar()
                    }
                }
            )
            .id(selectedSession)
#if DEBUG
            .overlay { LayoutFrameProbe(identifier: "session-detail-frame") }
#endif
        } else {
            ContentUnavailableView(
                "No session selected",
                systemImage: "rectangle.stack",
                description: Text("Choose a session to view its transcript.")
            )
            .background(.ccBackground)
        }
    }

    private func sidebarDragChanged(translationX: CGFloat, sidebarWidth: CGFloat) {
        guard horizontalSizeClass == .regular else { return }
        if regularSidebarDragStartProgress == nil {
            regularSidebarDragStartProgress = regularSidebarProgress
        }
        guard let startProgress = regularSidebarDragStartProgress else { return }
        releaseDetailForSidebarMotion()
        regularSidebarProgress = min(1, max(0, startProgress + translationX / max(1, sidebarWidth)))
    }

    private func sidebarDragEnded(translationX: CGFloat, velocityX: CGFloat, sidebarWidth: CGFloat) {
        guard let startProgress = regularSidebarDragStartProgress else { return }
        regularSidebarDragStartProgress = nil
        let isOpening = startProgress == 0
        let progress = min(1, max(0, startProgress + translationX / sidebarWidth))
        let targetProgress: CGFloat
        if isOpening {
            targetProgress = progress > 0.4 || velocityX > 500 ? 1 : 0
        } else {
            targetProgress = progress < 0.6 || velocityX < -500 ? 0 : 1
        }
        moveSidebar(to: targetProgress, initialVelocity: Double(velocityX / sidebarWidth))
    }

    private func toggleSidebar() {
        moveSidebar(to: regularSidebarProgress == 0 ? 1 : 0, initialVelocity: 0)
    }

    private func showSidebar() {
        moveSidebar(to: 1, initialVelocity: 0)
    }

    private func moveSidebar(to target: CGFloat, initialVelocity: Double) {
        releaseDetailForSidebarMotion()
        withAnimation(sidebarAnimation(initialVelocity: initialVelocity)) {
            regularSidebarProgress = target
            columnVisibility = target == 1 ? .all : .detailOnly
        } completion: {
            fitDetailBesideSidebarIfSettled()
        }
    }

    private func releaseDetailForSidebarMotion() {
        guard regularDetailFitsBesideSidebar else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            regularDetailFitsBesideSidebar = false
        }
    }

    private func fitDetailBesideSidebarIfSettled() {
        guard regularSidebarProgress == 1, regularSidebarDragStartProgress == nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            regularDetailFitsBesideSidebar = true
        }
    }

    private func sidebarAnimation(initialVelocity: Double) -> Animation {
        if reduceMotion { return .linear(duration: 0.01) }
        return .interpolatingSpring(mass: 1, stiffness: 250, damping: 28, initialVelocity: initialVelocity)
    }

    private func sessionsList(isRegularSidebarHidden: Bool = false) -> some View {
        SessionsListView(
            controllers: listControllers,
            waking: wakingSessionIDs,
            subtitleOverride: model.selectedSession == nil ? nil : "",
            notice: sessionNotice,
            canCreateSession: !newSessionChoices.isEmpty,
            isRegularSidebarHidden: isRegularSidebarHidden,
            openSessionKey: openSessionKey,
            onSessionsLoaded: {
                await model.requestNotificationAuthorizationAfterSessionsLoaded()
            },
            onOpen: { controllerID, session in
                openSession(controllerID, session.id)
            },
            onRetry: { controllerID in model.connection(for: controllerID)?.store.resume() },
            onSignIn: { controllerID in model.signIn(controllerID: controllerID) },
            onSettings: { model.isSettingsPresented = true },
            onRefresh: {
                for connection in model.connections {
                    connection.store.resume()
                }
            },
            onInterrupt: { controllerID, session in
                guard let id = session.id, let store = model.connection(for: controllerID)?.store else { return }
                runAction { await store.interrupt(sessionID: id) }
            },
            onSetApprovalMode: { controllerID, session, mode in
                guard let id = session.id, let store = model.connection(for: controllerID)?.store else { return }
                runAction { await store.setApprovalMode(sessionID: id, mode: mode) }
            },
            onCopySessionID: { session in
                guard let id = session.id else { return }
                UIPasteboard.general.string = id
            },
            onNewSession: presentNewSession,
            onWake: wakeSession,
            onCopyAttachCommand: { sleeping in
                UIPasteboard.general.string = claudeAttachCommand(shortId: sleeping.shortId)
            },
            onArchive: { controllerID, sessionID, archived in
                guard let store = model.connection(for: controllerID)?.store else { return .failure(.network("Controller is unavailable.")) }
                return await store.archiveSession(id: sessionID, archived: archived)
            },
            onEnd: { controllerID, sessionID in
                guard let store = model.connection(for: controllerID)?.store else { return .failure(.network("Controller is unavailable.")) }
                return await store.endSession(id: sessionID)
            },
            onActionError: { model.actionError = $0 }
        )
    }

    /// The session the person is looking at. A phone's list covers its detail, so there it needs the detail column.
    private var openSessionKey: String? {
        guard let selected = model.selectedSession else { return nil }
        guard horizontalSizeClass == .regular || preferredCompactColumn == .detail else { return nil }
        return sleepingSessionKey(controllerID: selected.controllerID, sessionID: selected.sessionID)
    }

    private var openSessionLastReplyDate: Date? {
        guard let selected = model.selectedSession,
              let session = model.connection(for: selected.controllerID)?.store.sessions[selected.sessionID] else {
            return nil
        }
        return sessionLastReplyDate(session)
    }

    private struct OpenSessionReadTrigger: Equatable {
        let sessionKey: String?
        let lastReplyDate: Date?
        let isActive: Bool
    }

    private var openSessionReadTrigger: OpenSessionReadTrigger {
        OpenSessionReadTrigger(
            sessionKey: openSessionKey,
            lastReplyDate: openSessionLastReplyDate,
            isActive: scenePhase == .active
        )
    }

    private func startReadMarksIfNeeded() {
        var marks = SessionReadMarks(stored: readMarksStored)
        marks.startIfNeeded(now: Date())
        readMarksStored = marks.stored
    }

    private func markOpenSessionRead() {
        guard scenePhase == .active, let key = openSessionKey else { return }
        var marks = SessionReadMarks(stored: readMarksStored)
        marks.markRead(key: key, through: max(openSessionLastReplyDate ?? .distantPast, Date()))
        readMarksStored = marks.stored
    }

    private func openSession(_ controllerID: ControllerID, _ id: String?) {
        guard let id else { return }
        model.isNewSessionPresented = false
        model.selectedSession = SessionRef(controllerID: controllerID, sessionID: id)
        preferredCompactColumn = .detail
        if horizontalSizeClass == .compact {
            columnVisibility = .detailOnly
        }
    }

    private func synchronizeColumnVisibility() {
        guard model.selectedSession != nil else {
            columnVisibility = .all
            preferredCompactColumn = .sidebar
            return
        }
        if horizontalSizeClass == .compact {
            columnVisibility = .detailOnly
            preferredCompactColumn = .detail
        }
    }

    private func regularSidebarControls() -> some View {
        HStack(spacing: RegularHeaderMetrics.controlSpacing) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .frame(width: RegularHeaderMetrics.toggleSize, height: RegularHeaderMetrics.toggleSize)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Toggle sidebar")
            .accessibilityIdentifier("sidebar-toggle")

            if approvalsElsewhereCount > 0 {
                Button(action: showSidebar) {
                    Text(approvalsElsewhereText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ccAmber)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .glassEffect(.regular.interactive(), in: .capsule)
                .modifier(SidebarApprovalModifier(progress: regularSidebarProgress))
                .accessibilityIdentifier("approvals-elsewhere")
                .accessibilityLabel(approvalsElsewhereAccessibilityLabel)
            }
        }
        .padding(.leading, RegularHeaderMetrics.horizontalPadding)
        .padding(.top, RegularHeaderMetrics.topPadding)
    }

    private var approvalsElsewhereText: String {
        approvalsElsewhereCount == 1 ? "1 needs you" : "\(approvalsElsewhereCount) need you"
    }

    private var approvalsElsewhereAccessibilityLabel: String {
        approvalsElsewhereCount == 1 ? "1 session needs you" : "\(approvalsElsewhereCount) sessions need you"
    }

    private var approvalsElsewhereCount: Int {
        guard horizontalSizeClass == .regular,
              columnVisibility == .detailOnly,
              let selectedSession = model.selectedSession else { return 0 }
        var sessionKeys: Set<String> = []
        for connection in model.connections {
            let controllerID = connection.config.id
            for approval in connection.store.approvals {
                guard let sessionID = approval.sessionId else { continue }
                if controllerID == selectedSession.controllerID, sessionID == selectedSession.sessionID { continue }
                sessionKeys.insert(sleepingSessionKey(controllerID: controllerID, sessionID: sessionID))
            }
        }
        return sessionKeys.count
    }

    private var listControllers: [SessionsListController] {
        model.connections.map { connection in
            let store = connection.store
            return SessionsListController(
                id: connection.config.id,
                name: connection.config.displayName,
                kind: store.controllerInfo.kind,
                connection: listConnection(for: store),
                signInNeeded: store.connection == .unauthorized,
                sessions: store.sortedSessions,
                sleeping: store.sleeping,
                approvals: store.approvals,
                capabilities: store.controllerInfo.capabilities
            )
        }
    }

    /// Controllers that can start a session, in registry order.
    private var newSessionChoices: [NewSessionControllerChoice] {
        model.connections
            .filter { $0.store.supports(.newSession) }
            .map { NewSessionControllerChoice(id: $0.config.id, name: $0.config.displayName) }
    }

    private func consumeResumeNewSessionRequest() {
        guard model.shouldResumeNewSession else { return }
        model.shouldResumeNewSession = false
        presentNewSession()
    }

    private func presentNewSession() {
        let choices = newSessionChoices
        guard let first = choices.first else { return }
        if !choices.contains(where: { $0.id == newSessionControllerID }) {
            newSessionControllerID = first.id
        }
        if !model.isNewSessionPresented {
            newSessionPrompt = ""
        }
        model.isNewSessionPresented = true
        preferredCompactColumn = .detail
        if horizontalSizeClass == .compact {
            columnVisibility = .detailOnly
        }
    }

    private var actionErrorTitle: String {
        if case .commandsUnavailable = model.actionError { return "Commands unavailable" }
        if case .readOnly = model.actionError { return "Read-only" }
        return "Action failed"
    }

    private func wakeSession(_ controllerID: ControllerID, _ sleeping: SleepingSession) {
        guard let store = model.connection(for: controllerID)?.store else { return }
        let key = sleepingSessionKey(controllerID: controllerID, sessionID: sleeping.id)
        guard wakingSessionIDs.insert(key).inserted else { return }
        wakeFailures.removeValue(forKey: key)
        openSession(controllerID, sleeping.id)

        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard store.sessions[sleeping.id]?.live != true else {
                wakingSessionIDs.remove(key)
                return
            }
            wakingSessionIDs.remove(key)
            wakeFailures[key] = "The session did not appear after waking."
        }
        Task { @MainActor in
            do {
                _ = try await store.wakeSession(id: sleeping.id)
                guard store.sessions[sleeping.id]?.live == true else { return }
                timeoutTask.cancel()
                wakingSessionIDs.remove(key)
                wakeFailures.removeValue(forKey: key)
            } catch {
                timeoutTask.cancel()
                wakingSessionIDs.remove(key)
                wakeFailures[key] = (error as? APIError)?.daemonMessage ?? error.localizedDescription
            }
        }
    }

    private func listConnection(for store: AppStore) -> SessionsListView.Connection {
        switch store.connection {
        case .live:
            return .live
        case .reconnecting, .connecting:
            return .reconnecting
        case .offline(let lastUpdated, _):
            return .offline(updatedAt: lastUpdated ?? store.lastUpdated ?? .now)
        case .offlineUnreadable(let lastUpdated, _):
            return .unreadable(updatedAt: lastUpdated ?? store.lastUpdated ?? .now)
        case .unauthorized:
            return .offline(updatedAt: store.lastUpdated ?? .now)
        }
    }

    private func runAction(_ operation: @escaping () async -> Result<Void, ActionError>) {
        Task {
            if case .failure(let error) = await operation() {
                model.actionError = error
            }
        }
    }

    #if DEBUG
    private func connectionStateLabel(_ state: ConnectionState) -> String {
        switch state {
        case .live: "live"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .offline: "offline"
        case .offlineUnreadable: "offline"
        case .unauthorized: "unauthorized"
        }
    }
    #endif
}

private struct SidebarRevealModifier: AnimatableModifier {
    var progress: CGFloat
    let sidebarWidth: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: -sidebarWidth * (1 - progress))
            .opacity(progress > 0.001 ? 1 : 0)
            .allowsHitTesting(progress > 0.001)
            .accessibilityHidden(progress <= 0.001)
    }
}

private struct SidebarApprovalModifier: AnimatableModifier {
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(max(0, min(1, 1 - progress)))
            .allowsHitTesting(progress <= 0.001)
            .accessibilityHidden(progress > 0.001)
    }
}

private struct SidebarPanCapture: UIViewRepresentable {
    let sidebarProgress: CGFloat
    let opensFromAnywhere: Bool
    let onSwipeDiagnostic: (String) -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SidebarCaptureView {
        let view = SidebarCaptureView()
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] view, window in
            coordinator?.updateAttachment(for: view, in: window)
        }
        return view
    }

    func updateUIView(_ view: SidebarCaptureView, context: Context) {
        context.coordinator.sidebarProgress = sidebarProgress
        context.coordinator.opensFromAnywhere = opensFromAnywhere
        context.coordinator.onSwipeDiagnostic = onSwipeDiagnostic
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.updateAttachment(for: view, in: view.window)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var sidebarProgress: CGFloat
        var opensFromAnywhere: Bool
        var onSwipeDiagnostic: (String) -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var captureView: SidebarCaptureView?
        weak var pan: SidebarPanGestureRecognizer?

        init(_ parent: SidebarPanCapture) {
            sidebarProgress = parent.sidebarProgress
            opensFromAnywhere = parent.opensFromAnywhere
            onSwipeDiagnostic = parent.onSwipeDiagnostic
            onChanged = parent.onChanged
            onEnded = parent.onEnded
        }

        func updateAttachment(for captureView: SidebarCaptureView, in window: UIWindow?) {
            self.captureView = captureView
            guard let window else {
                detachPan()
                return
            }
            let host = window
            if let pan, pan.view !== host {
                pan.view?.removeGestureRecognizer(pan)
                self.pan = nil
            }
            guard pan == nil else { return }
            let pan = SidebarPanGestureRecognizer(
                target: self,
                action: #selector(handlePan(_:))
            )
            pan.delegate = self
            pan.cancelsTouchesInView = false
            pan.requiresExclusiveTouchType = false
            host.addGestureRecognizer(pan)
            self.pan = pan
        }

        private func detachPan() {
            guard let pan else { return }
            pan.view?.removeGestureRecognizer(pan)
            self.pan = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? SidebarPanGestureRecognizer,
                  let view = pan.view,
                  let captureView else { return false }
            let initialLocation = pan.initialLocation ?? pan.location(in: view)
            // Direction comes from the distance moved so far. The speed at this instant may not be
            // reliable for a swipe that starts at the screen edge.
            let translation = pan.translation(in: view)
            let movement = translation == .zero ? pan.velocity(in: view) : translation
            if sidebarProgress >= 0.999 {
                // The open sidebar closes on a leftward swipe, starting on it or on the detail.
                guard movement.x < 0, abs(movement.x) > abs(movement.y) * 1.5 else { return false }
                return contentClaimingSwipe(from: pan.initialView, in: captureView) == nil
            }
            guard sidebarProgress <= 0.001, movement.x > 0, abs(movement.x) > abs(movement.y) else { return false }
            let stripFrame = captureView.convert(captureView.bounds, to: view)
            if stripFrame.contains(initialLocation) {
                return screenOwningSwipe(from: pan.initialView, in: captureView) == nil
            }
            let claim = contentClaimingSwipe(from: pan.initialView, in: captureView)
            onSwipeDiagnostic("claim=\(claim ?? "none"),anywhere=\(opensFromAnywhere),x=\(movement.x),y=\(movement.y)")
            // Away from the edge a steeper angle is needed, so a vertical scroll isn't taken for a swipe.
            return opensFromAnywhere && abs(movement.x) > abs(movement.y) * 1.5 && claim == nil
        }

        /// What under the touch has its own use for a rightward drag, or sits outside the split view:
        /// a sheet, a pushed screen (its swipe goes back), text input or a sideways scroller. Nil if nothing.
        private func contentClaimingSwipe(from touchedView: UIView?, in captureView: UIView) -> String? {
            if let screen = screenOwningSwipe(from: touchedView, in: captureView) { return screen }
            guard let hitView = touchedView else { return "no-view" }
            var ancestor: UIView? = hitView
            while let current = ancestor {
                if current is UITextField { return "text-field" }
                if let textView = current as? UITextView, textView.isEditable { return "text-view" }
                if let scrollView = current as? UIScrollView, scrollView.contentSize.width > scrollView.bounds.width + 1 {
                    return "scroller-\(scrollView.contentSize.width)-\(scrollView.bounds.width)"
                }
                ancestor = current.superview
            }
            return nil
        }

        /// A sheet or pushed screen above the split view: the swipe is theirs, even from the edge. Nil if neither.
        private func screenOwningSwipe(from touchedView: UIView?, in captureView: UIView) -> String? {
            guard let rootView = captureView.window?.rootViewController?.view else { return "no-root" }
            guard let hitView = touchedView else { return "no-view" }
            guard hitView.isDescendant(of: rootView) else { return "presented" }
            var responder: UIResponder? = hitView
            while let current = responder {
                if let navigation = current as? UINavigationController, navigation.viewControllers.count > 1 {
                    return "pushed"
                }
                responder = current.next
            }
            return nil
        }

        /// A sidebar drag shouldn't also scroll the transcript it started on.
        private func cancelScrolling(from touchedView: UIView?) {
            var ancestor = touchedView
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.panGestureRecognizer.isEnabled = false
                    scrollView.panGestureRecognizer.isEnabled = true
                }
                ancestor = current.superview
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard otherGestureRecognizer is UIPanGestureRecognizer else { return false }
            return !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
        }

        @objc func handlePan(_ recognizer: SidebarPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            switch recognizer.state {
            case .began:
                cancelScrolling(from: recognizer.initialView)
                onChanged(translation.x)
            case .changed:
                onChanged(translation.x)
            case .ended, .cancelled, .failed:
                onEnded(translation.x, recognizer.velocity(in: view).x)
            default:
                break
            }
        }
    }
}

private final class SidebarCaptureView: UIView {
    var onWindowChange: ((SidebarCaptureView, UIWindow?) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        onWindowChange?(self, newWindow)
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(self, window)
    }
}

private final class SidebarPanGestureRecognizer: UIPanGestureRecognizer {
    var initialLocation: CGPoint?
    weak var initialView: UIView?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, let view else { return }
        initialLocation = touch.location(in: view)
        initialView = touch.view
    }

    override func reset() {
        initialLocation = nil
        initialView = nil
        super.reset()
    }
}

#if DEBUG
private struct LayoutFrameProbe: View {
    let identifier: String

    var body: some View {
        GeometryReader { proxy in
            Text(frameDescription(proxy.frame(in: .global)))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier(identifier)
        }
        .allowsHitTesting(false)
    }

    private func frameDescription(_ frame: CGRect) -> String {
        "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"
    }
}
#endif
