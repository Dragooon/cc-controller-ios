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
    @State private var regularHeaderTopInset: CGFloat = 0
    @State private var regularSidebarDragStartProgress: CGFloat?
    @GestureState private var regularSidebarDragActive = false
    @State private var allowFeedbackCount = 0
    @State private var denyFeedbackCount = 0
    @State private var isNewSessionPresented = false
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
        .sensoryFeedback(.success, trigger: allowFeedbackCount)
        .sensoryFeedback(.warning, trigger: denyFeedbackCount)
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
        .onAppear(perform: synchronizeColumnVisibility)
        .onChange(of: model.selectedSession) { _, _ in
            synchronizeColumnVisibility()
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            if newSizeClass == .regular {
                columnVisibility = .all
                preferredCompactColumn = .sidebar
                regularSidebarProgress = 1
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
        GeometryReader { proxy in
            let sidebarWidth = min(360, max(300, proxy.size.width * 0.3))
            let remainingWidth = proxy.size.width - sidebarWidth
#if DEBUG
            let forceOverlay = ProcessInfo.processInfo.arguments.contains("-CCSidebarLayout")
                && ProcessInfo.processInfo.arguments.contains("overlay")
#else
            let forceOverlay = false
#endif
            let layoutMode = forceOverlay || remainingWidth < 440 ? "overlay" : "push"
            regularSplitContent(
                width: proxy.size.width,
                height: proxy.size.height,
                topInset: regularHeaderTopInset,
                sidebarWidth: sidebarWidth,
                isOverlay: forceOverlay || remainingWidth < 440
            )
#if DEBUG
            .overlay {
                Text(" ")
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityIdentifier("regular-layout-metrics")
                    .accessibilityValue("width=\(proxy.size.width),topInset=\(regularHeaderTopInset),sidebar=\(sidebarWidth),remaining=\(remainingWidth),mode=\(layoutMode)")
            }
#endif
            .overlay {
                NavigationBarMetricsReader { centerY in
                    // UINavigationBar's content row sits 5 pt above its outer frame center.
                    let inset = max(0, centerY - 27)
                    guard abs(regularHeaderTopInset - inset) > 0.5 else { return }
                    regularHeaderTopInset = inset
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }

    private func regularSplitContent(
        width: CGFloat,
        height: CGFloat,
        topInset: CGFloat,
        sidebarWidth: CGFloat,
        isOverlay: Bool
    ) -> some View {
        let isClosingSidebar = regularSidebarDragStartProgress.map { $0 > 0 } ?? false
        return ZStack(alignment: .leading) {
            regularDetailColumn(width: width, sidebarWidth: sidebarWidth, isOverlay: isOverlay)
            regularSidebarScrim(isOverlay: isOverlay)
            regularSidebarColumn(sidebarWidth: sidebarWidth, topInset: topInset, isOverlay: isOverlay)
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
            regularSidebarControls(topInset: topInset)
        }
        .onChange(of: regularSidebarDragActive) { _, isActive in
            guard !isActive, regularSidebarDragStartProgress != nil else { return }
            DispatchQueue.main.async {
                guard let startProgress = regularSidebarDragStartProgress else { return }
                let translationX = (regularSidebarProgress - startProgress) * sidebarWidth
                sidebarDragEnded(
                    translationX: translationX,
                    velocityX: 0,
                    sidebarWidth: sidebarWidth
                )
            }
        }
    }

    private func regularDetailColumn(width: CGFloat, sidebarWidth: CGFloat, isOverlay: Bool) -> some View {
        let shift = isOverlay ? 0 : sidebarWidth * regularSidebarProgress
        return regularDetailNavigation()
            .frame(width: max(0, width - shift))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(x: shift)
    }

    private func regularDetailNavigation() -> some View {
        NavigationStack {
            regularDetailContent()
        }
    }

    private func regularDetailContent() -> some View {
        detailView()
    }

    private func regularSidebarScrim(isOverlay: Bool) -> some View {
        Color.black
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .modifier(SidebarScrimModifier(progress: regularSidebarProgress, isOverlay: isOverlay))
            .onTapGesture { toggleSidebar() }
            .zIndex(0.5)
    }

    private func regularSidebarColumn(sidebarWidth: CGFloat, topInset: CGFloat, isOverlay: Bool) -> some View {
        sessionsList(
            topInset: topInset,
            isRegularSidebarHidden: regularSidebarProgress <= 0.001,
            closeOnOpen: isOverlay
        )
            .accessibilityHidden(regularSidebarProgress <= 0.001)
            .frame(width: sidebarWidth)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(width: 1 / displayScale)
                    .frame(maxHeight: .infinity)
            }
            .simultaneousGesture(sidebarDragGesture(sidebarWidth: sidebarWidth), including: .all)
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
            width: regularSidebarProgress > 0 || isClosingSidebar ? 80 : 20,
            height: height
        )
        .accessibilityIdentifier(
            regularSidebarProgress > 0 || isClosingSidebar ? "sidebar-close-strip" : "sidebar-edge-strip"
        )
        .zIndex(2)
    }

    @ViewBuilder
    private func detailView() -> some View {
        if isNewSessionPresented {
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

    private func sidebarDragGesture(sidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($regularSidebarDragActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard horizontalSizeClass == .regular else { return }
                if regularSidebarDragStartProgress == nil {
                    guard abs(value.translation.width) >= 12,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    let startsAtLeadingEdge = regularSidebarProgress < 0.001 && value.translation.width > 0
                    let startsInSidebar = regularSidebarProgress > 0.5 && value.translation.width < 0
                    guard startsAtLeadingEdge || startsInSidebar else { return }
                    regularSidebarDragStartProgress = regularSidebarProgress
                }
                sidebarDragChanged(translationX: value.translation.width, sidebarWidth: sidebarWidth)
            }
            .onEnded { value in
                if regularSidebarDragStartProgress == nil,
                   abs(value.translation.width) >= 12,
                   abs(value.translation.width) > abs(value.translation.height),
                   regularSidebarProgress > 0.5,
                   value.translation.width < 0 {
                    regularSidebarDragStartProgress = regularSidebarProgress
                }
                sidebarDragEnded(
                    translationX: value.translation.width,
                    velocityX: (value.predictedEndTranslation.width - value.translation.width) / 0.2,
                    sidebarWidth: sidebarWidth
                )
            }
    }

    private func sidebarDragChanged(translationX: CGFloat, sidebarWidth: CGFloat) {
        guard horizontalSizeClass == .regular else { return }
        if regularSidebarDragStartProgress == nil {
            regularSidebarDragStartProgress = regularSidebarProgress
        }
        guard let startProgress = regularSidebarDragStartProgress else { return }
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
        withAnimation(sidebarAnimation(initialVelocity: Double(velocityX / sidebarWidth))) {
            regularSidebarProgress = targetProgress
            columnVisibility = targetProgress == 1 ? .all : .detailOnly
        }
    }

    private func toggleSidebar() {
        let target: CGFloat = regularSidebarProgress == 0 ? 1 : 0
        withAnimation(sidebarAnimation(initialVelocity: 0)) {
            regularSidebarProgress = target
            columnVisibility = target == 1 ? .all : .detailOnly
        }
    }

    private func showSidebar() {
        withAnimation(sidebarAnimation(initialVelocity: 0)) {
            regularSidebarProgress = 1
            columnVisibility = .all
        }
    }

    private func sidebarAnimation(initialVelocity: Double) -> Animation {
        if reduceMotion { return .linear(duration: 0.01) }
        return .interpolatingSpring(mass: 1, stiffness: 250, damping: 28, initialVelocity: initialVelocity)
    }

    private func sessionsList(
        topInset: CGFloat = 0,
        isRegularSidebarHidden: Bool = false,
        closeOnOpen: Bool = false
    ) -> some View {
        SessionsListView(
            controllers: listControllers,
            waking: wakingSessionIDs,
            subtitleOverride: model.selectedSession == nil ? nil : "",
            notice: sessionNotice,
            canCreateSession: !newSessionChoices.isEmpty,
            regularHeaderTopInset: topInset,
            isRegularSidebarHidden: isRegularSidebarHidden,
            onSessionsLoaded: {
                await model.requestNotificationAuthorizationAfterSessionsLoaded()
            },
            onOpen: { controllerID, session in
                openSession(controllerID, session.id)
                if closeOnOpen { toggleSidebar() }
            },
            onAllow: { controllerID, approval in
                performApprovalDecision(approval, controllerID: controllerID, scope: .once)
            },
            onDeny: { controllerID, approval in
                performApprovalDeny(approval, controllerID: controllerID)
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

    private func openSession(_ controllerID: ControllerID, _ id: String?) {
        guard let id else { return }
        isNewSessionPresented = false
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

    private func regularSidebarControls(topInset: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .frame(width: 44, height: 44)
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
        .padding(.leading, 16)
        .padding(.top, topInset)
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
                deciding: store.deciding,
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

    private func presentNewSession() {
        let choices = newSessionChoices
        guard let first = choices.first else { return }
        if !choices.contains(where: { $0.id == newSessionControllerID }) {
            newSessionControllerID = first.id
        }
        if !isNewSessionPresented {
            newSessionPrompt = ""
        }
        isNewSessionPresented = true
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

    private func performApprovalDecision(_ approval: Approval, controllerID: ControllerID, scope: ApprovalScope) {
        guard let store = model.connection(for: controllerID)?.store else { return }
        Task { @MainActor in
            let result = await store.allow(approval, scope: scope)
            switch result {
            case .success:
                allowFeedbackCount += 1
            case .failure(let error):
                if error != .waitingInTerminal { model.actionError = error }
            }
        }
    }

    private func performApprovalDeny(_ approval: Approval, controllerID: ControllerID) {
        guard let store = model.connection(for: controllerID)?.store else { return }
        Task { @MainActor in
            let result = await store.deny(approval)
            switch result {
            case .success:
                denyFeedbackCount += 1
            case .failure(let error):
                if error != .waitingInTerminal { model.actionError = error }
            }
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

private struct SidebarScrimModifier: AnimatableModifier {
    var progress: CGFloat
    let isOverlay: Bool

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(isOverlay ? 0.25 * progress : 0)
            .allowsHitTesting(isOverlay && progress > 0.001)
            .accessibilityHidden(!isOverlay || progress <= 0.001)
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

private struct NavigationBarMetricsReader: UIViewRepresentable {
    let onCenterY: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window,
                  let bar = navigationBars(in: window)
                    .filter({ !$0.isHidden && $0.alpha > 0 && $0.bounds.height > 0 })
                    .max(by: { $0.convert($0.bounds, to: window).width < $1.convert($1.bounds, to: window).width }) else { return }
            if let sessionInfo = findView(withAccessibilityIdentifier: "session-info", in: window) {
                onCenterY(sessionInfo.convert(sessionInfo.bounds, to: window).midY)
                return
            }
            let barFrame = bar.convert(bar.bounds, to: window)
            let subviewFrames = descendantFrames(in: bar, window: window)
            let contentCandidates = subviewFrames.filter { frame in
                frame.width >= barFrame.width * 0.8
                    && frame.height >= 30
                    && frame.height <= barFrame.height
            }
            let contentFrame = contentCandidates.min { left, right in
                abs(left.height - 44) < abs(right.height - 44)
            }
            onCenterY((contentFrame ?? barFrame).midY)
        }
    }

    private func descendantFrames(in view: UIView, window: UIWindow) -> [CGRect] {
        view.subviews.flatMap { subview in
            [subview.convert(subview.bounds, to: window)] + descendantFrames(in: subview, window: window)
        }
    }

    private func findView(withAccessibilityIdentifier identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews {
            if let match = findView(withAccessibilityIdentifier: identifier, in: subview) { return match }
        }
        return nil
    }

    private func navigationBars(in view: UIView) -> [UINavigationBar] {
        view.subviews.flatMap { subview in
            (subview as? UINavigationBar).map { [$0] } ?? navigationBars(in: subview)
        }
    }
}

private struct SidebarPanCapture: UIViewRepresentable {
    let sidebarProgress: CGFloat
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
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.updateAttachment(for: view, in: view.window)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var sidebarProgress: CGFloat
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var captureView: SidebarCaptureView?
        weak var pan: SidebarPanGestureRecognizer?

        init(_ parent: SidebarPanCapture) {
            sidebarProgress = parent.sidebarProgress
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
            let stripFrame = captureView.convert(captureView.bounds, to: view)
            guard stripFrame.contains(initialLocation) else { return false }
            let velocity = pan.velocity(in: view)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
            return sidebarProgress <= 0.001 && velocity.x > 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard otherGestureRecognizer is UIPanGestureRecognizer else { return false }
            return !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is SidebarPanGestureRecognizer
                && otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
        }

        @objc func handlePan(_ recognizer: SidebarPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            switch recognizer.state {
            case .began, .changed:
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, let view else { return }
        initialLocation = touch.location(in: view)
    }

    override func reset() {
        initialLocation = nil
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
