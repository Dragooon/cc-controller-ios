import CCKit
import SwiftUI
import UIKit

struct MainSplitView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var allowFeedbackCount = 0
    @State private var denyFeedbackCount = 0
    @State private var isNewSessionPresented = false
    @State private var newSessionControllerID: ControllerID = .mac
    /// Keys from `sleepingSessionKey(controllerID:sessionID:)`.
    @State private var wakingSessionIDs: Set<String> = []
    @State private var wakeError: String?
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
            "Couldn't wake session",
            isPresented: Binding(
                get: { wakeError != nil },
                set: { isPresented in
                    if !isPresented { wakeError = nil }
                }
            )
        ) {
            Button("OK") { wakeError = nil }
        } message: {
            Text(wakeError ?? "The session could not be woken.")
        }
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
        .sheet(isPresented: $isNewSessionPresented) {
            let store = model.connection(for: newSessionControllerID)?.store ?? model.primaryStore
            let controllerID = newSessionControllerID
            NewSessionView(
                store: store,
                controllerChoices: newSessionChoices,
                selectedControllerID: $newSessionControllerID
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
            .id(newSessionControllerID)
        }
        .onAppear(perform: synchronizeColumnVisibility)
        .onChange(of: model.selectedSession) { _, _ in
            synchronizeColumnVisibility()
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            if newSizeClass == .regular {
                columnVisibility = .all
                preferredCompactColumn = .sidebar
            } else {
                synchronizeColumnVisibility()
            }
        }
    }

    @ViewBuilder
    private func splitView() -> some View {
        if horizontalSizeClass == .regular {
            splitViewContent()
                .navigationSplitViewStyle(.balanced)
                .tint(.ccAccent)
                .background(.ccBackground)
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
            if horizontalSizeClass == .regular {
                sessionsList()
#if DEBUG
                    .overlay { LayoutFrameProbe(identifier: "sessions-list-frame") }
#endif
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
            } else {
                sessionsList()
            }
        } detail: {
            if let selectedSession = model.selectedSession,
               let selectedConnection = model.connection(for: selectedSession.controllerID) {
                SessionScreen(
                    sessionID: selectedSession.sessionID,
                    store: selectedConnection.store,
                    model: model,
                    approvalsElsewhereCount: approvalsElsewhereCount,
                    onShowApprovalsElsewhere: { columnVisibility = .all }
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
    }

    private func sessionsList() -> some View {
        SessionsListView(
            controllers: listControllers,
            waking: wakingSessionIDs,
            subtitleOverride: model.selectedSession == nil ? nil : "",
            notice: sessionNotice,
            canCreateSession: !newSessionChoices.isEmpty,
            onSessionsLoaded: {
                await model.requestNotificationAuthorizationAfterSessionsLoaded()
            },
            onOpen: { controllerID, session in openSession(controllerID, session.id) },
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
                UIPasteboard.general.string = "claude attach \(sleeping.shortId)"
            }
        )
    }

    private func openSession(_ controllerID: ControllerID, _ id: String?) {
        guard let id else { return }
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
        isNewSessionPresented = true
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
        Task { @MainActor in
            defer { wakingSessionIDs.remove(key) }
            do {
                let appeared = try await store.wakeSession(id: sleeping.id)
                guard appeared else {
                    wakeError = "The session did not appear after waking."
                    return
                }
                openSession(controllerID, sleeping.id)
            } catch {
                wakeError = (error as? APIError)?.daemonMessage ?? error.localizedDescription
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
                model.actionError = error
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
                model.actionError = error
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
